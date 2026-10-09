# QemuCP — contexto para Claude Code

Fork de HestiaCP para Ubuntu 24.04, en producción en varios servidores
(qemugen.com / laprimera). Rama de trabajo: `release`. Hablar en español.

## Lo primero que hay que entender

**El panel se compila e instala desde este fork, no desde apt.**
`install/qemucp_install.sh` clona la rama `release`, compila el `.deb` de
`hestia` con `src/hst_autocompile.sh --hestia --noinstall --keepbuild '~localsrc'`
(unos 45 s, deja el paquete en `/tmp/hestiacp-src/deb/`), lo instala con
`hst-install.sh -D <dir>` y lo bloquea con `apt-mark hold hestia`.
`hestia-nginx` y `hestia-php` siguen viniendo de apt: el instalador de
HestiaCP cae a apt para ellos si no están en el directorio de `-D`.
Consecuencias:

- Lo que se cambie en `bin/`, `func/`, `web/` o `install/common/packages/`
  **llega al servidor** dentro del paquete. Comprobado extrayendo el `.deb`.
- Upstream no puede pisar nada: una versión nueva de HestiaCP no se instala
  hasta que se sincronice el fork y se recompile.
- `web/inc/vendor` **no va en el paquete**, tampoco en el oficial: lo crea
  `v-add-sys-dependencies` (composer) al final de `hst-install`. Un
  `PHP Fatal error ... vendor/autoload.php` en un árbol de pruebas es por
  eso, no un fallo del paquete.
- `/usr/local/hestia/conf/qemucp-origen` dice si se instaló desde `fork` o
  desde `apt` (`QEMUCP_DESDE_APT=yes`, o si la compilación falla). El hook
  lo usa: en instalaciones desde el fork **no** ejecuta
  `qemucp-rebrand.sh`, porque todo lo que injerta ya va en el paquete, y
  descargarlo de `release` en ese momento podría mezclar PHP de dos
  versiones.

Actualizar un servidor: sincronizar upstream en el fork, recompilar y
`dpkg -i` el `.deb` (el `hold` no bloquea `dpkg -i`). El `postinst` llama al
hook al final.

**El único hook que HestiaCP ejecuta es `/etc/hestiacp/hooks/post_install.sh`**,
invocado al final de `src/deb/hestia/postinst`. La ruta
`/usr/local/hestia/data/hooks/post_update.sh` que se usó durante un tiempo
**no se ejecuta nunca**: tres hooks escritos ahí (marca, parches,
post_add_user) resultaron ser código muerto, y de ahí que el
`session.save_path` duplicado y la marca reaparecieran en cada
actualización. Lo instala `install/instalar-hook.sh`. Ojo al orden dentro
del hook: el `postinst` ya ha ejecutado `upgrade_rebuild_users` **antes**
de llamarlo, así que si se tocan plantillas hay que regenerar los pools a
mano después.

Si añades un parche a `bin/` o `func/`, **tiene que** ir acompañado de su
script en `install/` y su paso en `install/qemucp_install.sh`. Si no, no
sobrevive.

## Cómo probar sin romper producción

No hace falta un servidor real. HestiaCP se puede ejecutar contra un árbol
falso: copiar `bin/ func/ web/` a `/usr/local/hestia`, escribir
`/etc/hestiacp/hestia.conf` y `$HESTIA/conf/hestia.conf` (**sin** la clave
`USER_DATA`, que `func/main.sh` calcula por usuario y una definición manual
la pisa), crear `data/{users,packages,templates,ips,queue,extensions}`,
copiar las plantillas de `install/common/templates` y
`install/deb/templates/web`, y poner stubs de `systemctl`, `nginx`,
`apache2`, `named`, `exim4`, `dovecot`, `mysql`, `quota`, `setfacl`.

Hacen falta además: `idn2` instalado, `$HESTIA/php/bin/php` (symlink al php
del sistema), `$HESTIA/log/error.log`, `data/extensions/public_suffix_list.dat`
(HestiaCP lo descarga de publicsuffix.org y falla sin red),
`/etc/php/$V/fpm/pool.d`, `/var/log/apache2/domains`, y `nologin` en
`/etc/shells`.

Con eso se ejecutan de verdad `v-add-user`, `v-add-web-domain`,
`v-add-domain`, `v-change-user-package`, `v-update-user-counters` y los
`v-list-*`. **Ejecutar los comandos reales, no reimplementar su lógica**:
el fallo de `U_WEB_SUBDOMAINS` (se calculaba y no se guardaba, faltaba
`update_user_value`) solo salió así.

Validar siempre con `python3 -c "import json; json.load(...)"` la salida
`json` de los `v-list-*` que se toquen: si se rompe, la página
correspondiente del panel deja de cargar entera.

**No cambiar el orden de columnas de los formatos `plain` y `csv`.** Hay
scripts propios que parsean por posición. Las claves nuevas van solo en
`json` y en el listado legible.

## Parches propios (ya aplicados, no re-descubrir)

### Límite de subdominios separado (`install/parche-subdominios.sh`)
HestiaCP cuenta todo dominio web en `WEB_DOMAINS`, así que un subdominio
gasta el mismo cupo que un dominio adicional. En cPanel son cupos
distintos. Se añadió `WEB_SUBDOMAINS` a los paquetes.

- `count_web_domains_split()` en `func/main.sh`: separa dominios de nivel
  superior de subdominios de otro dominio del mismo usuario. Es
  independiente del orden de creación.
- `web_quota_key()`: decide el cupo de un dominio. La usan
  `v-add-web-domain` **y** `v-add-domain`. Este último pre-comprueba el
  cupo por su cuenta y, si está lleno, **se salta la creación del vhost sin
  devolver error**; con un plan de 1 dominio + N subdominios eso dejaba
  cada subdominio sin web, solo con zona DNS y correo.
- Compatibilidad: clave ausente o vacía = esquema antiguo. El split es por
  paquete, para que los clientes existentes no cambien de comportamiento.
  El formulario de paquetes muestra el campo **vacío** en los paquetes
  heredados a propósito: si mostrase `unlimited`, editar cualquier otro
  campo activaría el esquema nuevo sin pedirlo.
- Modos: `--listar`, `--plan PLAN DOM SUB`, `--usuario USUARIO DOM SUB`.
- `DNS_DOMAINS` y `MAIL_DOMAINS` se ponen en `unlimited`: cada subdominio
  es también zona DNS y dominio de correo, y si se quedan cortos el panel
  crea el subdominio a medias.
- `WEB_DOMAINS=1` significa "solo el principal, sin adicionales".

### Cola de reinicios (`install/arreglar-crons.sh`)
HestiaCP no reinicia servicios al crear un dominio: los encola en
`data/queue/restart.pipe` y los procesa un cron de `hestiaweb`
(`*/2 * * * * v-update-sys-queue restart`). Si ese crontab falta, está
incompleto, o no es `hestiaweb:hestiaweb` con modo `600`, **cron lo
descarta sin registrar nada**. Síntoma: se crea una web y el dominio no
resuelve aunque esté apuntando, hasta que se guarda la zona en el panel
(eso fuerza un reinicio inmediato) y entonces funciona "sin haber tocado
nada". Atajo: `v-restart-dns yes`.

### Otros ya corregidos
- **`session.save_path` duplicado**: la plantilla de HestiaCP trae
  `session.save_path = /home/%user%/tmp` y el instalador añadía el bloque
  de Redis sin quitarla. Rompía PrestaShop, Joomla y Moodle. Se arregla en
  las plantillas de `data/templates/web/php-fpm/*.tpl`, **no** en los pools
  generados, o vuelve en el siguiente rebuild.
  **Causa principal, encontrada después**: la llave de idempotencia del
  instalador era `grep -q "memory_limit = 512M"`, pero lo escrito es
  `php_admin_value[memory_limit] = 512M` (con `]`). No coincidía nunca, así
  que cada vez que se relanzaba el instalador se añadía otro bloque con otra
  línea `session.save_path`. La llave es ahora la línea de comentario
  `; -- QemuCP: Optimizaciones de rendimiento --`. El hook normaliza las
  plantillas a exactamente un bloque completo. **Al escribir una llave de
  idempotencia, comprobar que coincide con el texto que se escribe.**
- **`info()` no estaba definida** y el instalador la llamaba en ocho sitios;
  con `set -e`, cualquiera que se ejecutase abortaba la instalación con
  "command not found". Al añadir un helper, buscar que esté definido.
- **File Manager "Error desconocido"**: `HestiaAuth.php` lee
  `$_SESSION["root"]`, clave que el panel nunca define.
- **Bucle de login** (`array_reverse(): null given`): el fork pinned a una
  versión mientras apt sirve otra. Mantener `install/hst-install-ubuntu.sh`
  sincronizado con upstream.

## Migrador de cPanel (`install/migrate/cpanel-import.sh`)

Crea la cuenta con el paquete `default` (ambos cupos `unlimited`), así que
ningún límite bloquea una importación. Clasifica como subdominio solo lo
que acaba en `.DOMINIO_PRINCIPAL`; los subdominios de addons van a la lista
de addons, pero eso solo afecta a sus logs y a dónde copia ficheros — el
conteo de cupos se recalcula aparte.

Fallos ya corregidos, no reintroducir: permisos de correo
(`Debian-exim:mail` en el directorio, `dovecot:mail` en `passwd`, modo
`660`); registros DNS A/CNAME/TXT descartados por estar el bloque de
escritura dentro de un `if [[ -n "$rec_prio" ]]`; `grep -c` devolviendo 1
sin coincidencias y abortando bajo `set -e`; `case` con continuaciones de
línea (bash no las parsea); versión de PHP mal resuelta (`8_1` en vez de
`8.1`); dominios con guion descartados por el regex; `.php-fpm.yaml`
registrado como alias; MX local no borrado cuando la prioridad no era 10;
correo externo detectado por lista fija de proveedores en vez de por
destino del MX; falta de `exit 0` marcando como fallidas las migraciones
correctas.

## Trampas recurrentes en producción

- **`_dmarc` duplicado**: el migrador trae el de cPanel y HestiaCP crea el
  suyo. Dos TXT `v=DMARC1` hacen que el verificador no pueda decidir y
  Proofpoint devuelve `554 5.7.5 Permanent error evaluating DMARC policy`.
  El de cPanel se reconoce por los `\;` escapados. Visto en
  `artifactum.com` y `ganaderiagranda.es`.
- **MX duplicados** con prioridad `0` los dos, uno al dominio pelado.
- **Certificado SNI de correo**: Exim y Dovecot lo buscan en
  `/usr/local/hestia/ssl/mail/mail.DOMINIO.crt`. Sin él sirven el del
  hostname y los clientes avisan. Se emite con
  `v-add-letsencrypt-domain USER DOMAIN '' yes`, y HestiaCP pide
  `mail.` **y** `webmail.`: si uno no resuelve al servidor, falla todo el
  certificado y consume intentos del límite.
- **Hostname del panel bajo el dominio de un cliente**:
  `v-add-letsencrypt-host` falla con `X belongs to a different user` porque
  `is_base_domain_owner` exige que el dominio base sea del mismo usuario.
  El hostname debe ir bajo un dominio propio, no de cliente.
- **Límites de Let's Encrypt**: 10 registros de cuenta por IP cada 3 h, 5
  validaciones fallidas por hora y dominio, 50 certificados por semana y
  dominio registrado. Comprobar que cada nombre resuelve al servidor
  **antes** de emitir.
- **Cadena de certificado incompleta** (`Verify return code: 21`): copiar
  el `.pem`, no el `.crt`.
- **imapsync**: no está en los repos de Ubuntu; se instala con las 32
  dependencias Perl de la lista oficial más el script de GitHub. Validar
  credenciales con `--justlogin` antes de migrar. Para el destino, usar
  `localhost:143 --nossl2 --notls2` y evitar de raíz los errores de
  certificado. Si el origen limita conexiones, `--maxsleep 2 --timeout 120`
  y `sleep 45` entre cuentas.

## El instalador

Un único fichero, `install/qemucp_install.sh`. Los scripts auxiliares
(`instalar-hook.sh`, `parche-subdominios.sh`, `arreglar-crons.sh`) van
**incrustados** como heredocs y se despliegan en el PASO 0 en `/opt/qemucp`;
los pasos 10C/10D/10E los copian a `$HESTIA/data/qemucp`, desde donde los usa
el hook. Si se edita uno de esos scripts en `install/`, **hay que
reincrustarlo** en el instalador: el PASO 0 debe dejarlos byte a byte
idénticos a los sueltos.

Clave de acceso: solo se guarda el hash SHA-256 (`QEMUCP_KEY_HASH`), porque
el repo es público. Se pide sin mostrarla, o por `QEMUCP_KEY` en
desatendido. **Nunca** como argumento: queda en el historial y se ve en
`ps`. `--set-pass` genera el hash de una clave nueva (mínimo 16
caracteres). El hash actual es el de la clave antigua, que estuvo en claro
en el repo público: hay que rotarla.

## Convenciones

Los scripts de `install/` son idempotentes, hacen backup antes de tocar
nada, verifican sintaxis (`bash -n`, `php -l`) y se revierten solos si algo
falla. Comentarios y salida en español, sin acentos en el código. Los
commits terminan con las líneas de atribución que pida la sesión.
