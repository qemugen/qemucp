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

## Prueba automática completa (CI)

Cada push a `release` lanza `.github/workflows/qemucp-ci.yml`: instala
QemuCP desde cero con `install/qemucp_install.sh` en un contenedor Ubuntu
24.04 con systemd real (`.github/docker/qemucp-ci.Dockerfile`), pasa
`test/qemucp.bats` (pruebas propias), relanza el instalador y repite las
pruebas, simula una actualización con `dpkg -i` para comprobar el hook, y
ejecuta la batería de HestiaCP (`test/test.bats`). El informe queda en la
rama **`ci-resultados`** (`RESULTADO.md` y logs): léelo con
`git fetch origin ci-resultados && git show origin/ci-resultados:RESULTADO.md`.
La clave de producción no se usa: el workflow genera una aleatoria y pone su
hash en una copia del instalador. `QEMUCP_FORK_SRC` hace que el instalador
compile el commit que se está probando en lugar de clonar `release`.

**Cada arreglo nuevo debería venir con su prueba en `test/qemucp.bats`.**

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
- **Plantillas php-fpm: se normalizan por directiva** (`qemucp_normalizar_tpl`,
  igual en el instalador y en el hook): se quita cualquier línea que defina
  algo que también define el bloque de QemuCP y se pone el bloque una vez.
  Buscar una línea concreta falló tres veces; la última, porque las
  `PHP-X_Y.tpl` salen de `multiphp.tpl`, que ya trae la línea de Redis.
- **Relanzar el instalador rompía nginx**: el paso de Brotli añadía sus
  `load_module` sin comprobar si ya estaban; duplicados, `nginx -t` falla,
  nginx no recarga y ningún `v-add-web-domain` funciona (código 20). Ahora
  comprueba y además elimina duplicados de relanzamientos anteriores.
- **fail2ban no arrancaba** (ni en servidores reales): el instalador
  sobreescribía el `jail.local` de HestiaCP con uno peor, y fail2ban no
  arranca ninguna jaula si falta un solo fichero de log (`auth.log` no existe
  hasta el primer acceso). Ahora se usa el `jail.local` del paquete, se crean
  los logs que falten y se comprueba que queda activo. `fail2ban-client -t`
  NO detecta los logs que faltan: solo falla al arrancar.
- **`dpkg -i` quita el `apt-mark hold`**: tras actualizar desde el fork, un
  `apt upgrade` metería el paquete de upstream. El hook lo reaplica con un
  proceso que espera a que dpkg suelte el bloqueo.
- **`info()` no estaba definida** y el instalador la llamaba en ocho sitios;
  con `set -e`, cualquiera que se ejecutase abortaba la instalación con
  "command not found". Al añadir un helper, buscar que esté definido.
- **File Manager "Error desconocido"**: `HestiaAuth.php` lee
  `$_SESSION["root"]`, clave que el panel nunca define.
- **Bucle de login** (`array_reverse(): null given`): el fork pinned a una
  versión mientras apt sirve otra. Mantener `install/hst-install-ubuntu.sh`
  sincronizado con upstream.

## Migrador de cPanel (`install/migrate/cpanel-import.sh`, v2.0)

Uso: `bash cpanel-import.sh backup.tar.gz [usuario] [plan]`. Probado en CI
con `test/cpanel-import.bats` sobre el backup sintético
`test/fixtures/make-cpanel-backup.sh` (añadir ahí cada caso nuevo que
falle en producción).

- Tipos de dominio desde `userdata/main`: addon (su subdominio interno
  `addon.principal.com` NO se crea), subdominios (también de addons y de
  aparcados), aparcados → alias del principal con `www`. Padres antes que
  hijos. Carpeta web de cada uno desde `documentroot` de su userdata.
- Antes de crear nada comprueba que el plan cubre dominios/subdominios
  (contando igual que `count_web_domains_split`), BBDD, correo, zonas,
  crons. `QEMUCP_IGNORAR_LIMITES=si` para forzar.
- Correo externo = MX preferente fuera del origen (también `mail.dominio`
  si en la zona apunta a otra IP). Forzar: `QEMUCP_CORREO_LOCAL=`/
  `QEMUCP_CORREO_EXTERNO=`. Externo: no se crea dominio de correo, se
  respetan MX/SPF/registros de correo del cliente (la plantilla se quita
  ANTES de importar).
- Contraseñas originales en el campo MD5 de `mail/DOM.conf` (si solo se
  tocan en `passwd`, cualquier rebuild las machaca). Reenviadores de `va/`,
  alias de dominio de `vad/` (cuentas solo-reenvío), catch-all, cuenta por
  defecto, cuotas, mdbox → `doveadm import`.
- DNS: solo los A que apuntan al origen pasan a este servidor (IP NAT si la
  hay); un SPF y un DMARC; DKIM propio; CAA con letsencrypt; sin registros
  de cPanel; cada subdominio web con su registro.
- En lote: en el cPanel `qemucp-export.sh cpanel all` (copias pkgacct);
  aquí `cpanel-import-lote.sh carpeta [plan]` o `lista.txt` (backup
  usuario plan). Resumen en `/root/qemucp-lote-*/RESUMEN.txt`. El
  importador se para si el usuario existe y no tiene el dominio principal
  (otro cliente; `QEMUCP_FUSIONAR=si`) o si un dominio está en otra cuenta.
- Reejecutable: no duplica DNS, crons ni alias; las BBDD se vacían y
  reimportan. Recarga web/proxy/php-fpm al final (todo se crea con
  restart=no). Informe en `/root/qemucp-import-USUARIO-*.txt`.

## Trampas recurrentes en producción

- **`_dmarc` y MX duplicados tras migrar**: QemuCP crea su `_dmarc` y su
  MX, y el migrador importaba también los de cPanel. Dos `_dmarc` hacen que
  el receptor no pueda elegir política (Proofpoint: `554 5.7.5 Permanent
error evaluating DMARC policy`); dos MX con prioridad 0 reparten el correo
  al azar. Visto en `artifactum.com` y `ganaderiagranda.es`. **Corregido en
  el migrador**: con correo local no importa los MX de cPanel que apuntan
  dentro de la zona, y del `_dmarc` conserva solo el del cliente (su
  política de producción), quitando el de QemuCP. Además limpia los `\;`
  que cPanel escribe en los TXT entre comillas.
- **`.user.ini` de cPanel (MultiPHP INI Editor) cuelga webs**: trae
  `session.save_path="/tmp"` (fuera de open_basedir), `zlib.output_compression=On`
  y `max_execution_time=180`; en haciendabolonia.com los procesos PHP-FPM se
  quedaban minutos sin responder (`AH01075 ... (polling)` en Apache, `upstream
  timed out` en nginx) mientras por consola la web cargaba en 2 s. **Corregido
  en el migrador** (`limpiar_php_ini_web`): solo deja memoria (tope 512M),
  tiempos (tope 60 s), max_input_vars, subidas (tope 256M), zona horaria y
  errores; original en `.user.ini.cpanel-orig`; `php.ini` de la web pasa a
  `.php.ini.cpanel-orig` (PHP-FPM no lo lee). Cuentas ya migradas:
  `install/migrate/arreglar-user-ini.sh [usuario ...]`.
- **Parches de PHP (`install/parche-php.sh`)**: Ubuntu no aplica solo las
  actualizaciones del repositorio de Ondrej, asi que PHP se quedaba sin
  parchear. El script actualiza todas las versiones instaladas, anade el PPA
  a unattended-upgrades (php2shell, CVE-2026-109618/109619, 21-oct-2026). La
  mitigacion (`session.upload_progress.enabled = 0` en
  `/etc/php/X.Y/fpm/conf.d/99-qemucp-seguridad.ini`) es SOLO con `--mitigar`:
  el usuario no puede quitarla sin hablar con sus clientes; `--quitar-mitigacion`
  la retira
  e informa de las webs en 7.x/8.0/8.1 (sin version oficial corregida). Lo
  ejecutan la instalacion (PASO 7) y `--actualizar`; a mano:
  `bash /usr/local/hestia/data/qemucp/parche-php.sh [--comprobar]`.
- **PHP interno del panel (hestia-php)**: el instalador compila `hestia-php`
  y `hestia-nginx` desde el fork (`src/deb/php/control`, ahora 8.5.12) en vez
  de bajarlos de apt.hestiacp.com (22-oct-2026: indice con Hash Sum mismatch
  y hestia-php 8.5.9 vulnerable a php2shell). `--actualizar` compila e
  instala hestia-php si el del fork es mas nuevo. Para un parche de PHP
  futuro: subir la version en `src/deb/php/control`. `apt-get update` del
  instalador va por `qemucp_apt_update` (no se para si un repositorio falla).
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
caracteres). La clave actual se generó al azar y solo está su hash; la
antigua (`QemuCP2024#Cloud`) estuvo en claro en el repo y ya no sirve.

## Actualizar (versión nueva de HestiaCP o corrección nuestra)

Los servidores tienen `hestia` en `apt-mark hold`: apt nunca lo cambia por
el de upstream. Una versión nueva de HestiaCP **nunca va directa a release**:

1. `.github/workflows/sync-upstream.yml` (cada lunes o a mano desde Actions):
   busca la última versión publicada (etiqueta X.Y.Z) de hestiacp/hestiacp;
   si es más nueva que la nuestra (`src/deb/hestia/control`), la fusiona en
   la rama **`sync/X.Y.Z`** (desde release), comprueba que siguen las piezas
   de QemuCP (bloques de `panel.php`, tema, lista de webs, instaladores...;
   una fusión "sin conflictos" puede quedarse con el fichero de upstream,
   así se perdió la pestaña de WordPress en la 1.10.3), sube la rama, lanza
   la prueba completa sobre ella y abre un issue. Con conflictos o piezas
   perdidas no sube nada y el issue explica cómo fusionar a mano.
2. La prueba de `sync/*` publica su informe en `ci-resultados-sync-X.Y.Z`
   (la de release sigue en `ci-resultados`); una rama no cancela la prueba
   de otra.
3. Si sale en verde, **se pasa sola a release**: la prueba de la rama
   `sync/*` lanza `promote-sync.yml` (automatico=true), que espera a que esa
   prueba termine, vuelve a comprobar que la última prueba de la rama es de
   su último commit y salió `success`, fusiona, prueba release y avisa por
   email. Si la prueba falla, email de aviso y release no se toca. También
   se puede lanzar a mano: Actions -> **Pasar a release una version probada**.
   Emails: secretos `MAIL_USERNAME` (Gmail), `MAIL_PASSWORD` (contraseña de
   aplicación) y `NOTIFY_EMAIL`; sin ellos todo funciona igual, sin correo.
4. En cada servidor: `bash qemucp_install.sh --actualizar` (pide la clave),
   primero en uno. Compila el fork, `dpkg -i` (el postinst migra y llama al
   hook), vuelve a poner el hold, comprueba el panel. Copia de `conf/` y
   `templates/` en `/root/qemucp-backups/actualizar-*`. Log:
   `/var/log/qemucp-actualizar.log`. También pasa al fork un servidor
   instalado desde apt.

Lo subido por un workflow con `GITHUB_TOKEN` no dispara `push`: por eso
`sync-upstream.yml` y `promote-sync.yml` lanzan la prueba con
`gh workflow run`.

Relanzar el instalador sin `--actualizar` NO actualiza el panel: solo
reaplica optimizaciones.

## Convenciones

Los scripts de `install/` son idempotentes, hacen backup antes de tocar
nada, verifican sintaxis (`bash -n`, `php -l`) y se revierten solos si algo
falla. Comentarios y salida en español, sin acentos en el código. Los
commits terminan con las líneas de atribución que pida la sesión.

## Tema propio de QemuCP (`qemucp`)

Hecho: `web/css/src/themes/qemucp.css`, con la identidad del logo
(`web/images/logo-header.svg`, blanco con nube cian): barra superior marino
con degradado y filo cian, acentos cian `#00c8f5` / azul `#1f7ae0`, tarjetas
redondeadas con sombra suave, login oscuro (el logo es blanco y no se veria
sobre blanco). Distribucion clara al estilo de Plesk. En las listas las acciones son botones con texto ("Editar
Dominio", "Suspender", "Borrar"...) en lugar de iconos, siempre visibles
(no solo al pasar el raton). "Borrar" va en rojo y la accion principal
(`shortcut-enter`) con el degradado de la marca.

Es **solo CSS**, sin tocar plantillas: muestra el
`<span class="u-hide-desktop">` que cada `.units-table-row-action-link` de
`web/templates/pages/list_*.php` ya lleva traducido, y oculta el `.fas`.
El texto es el de esas plantillas (p.ej. "Editar Dominio", no "Editar");
acortarlo exigiria tocar las plantillas. Si upstream anade una lista nueva
con acciones sin ese span, el boton saldria vacio: revisarlo al sincronizar.

Dónde está cada cosa:

- Nada de iconos sueltos para el usuario final. Ademas de las listas:
  barra superior con el texto bajo cada icono (las etiquetas
  `.top-bar-menu-link-label` ya vienen traducidas; la barra pasa a todo el
  ancho y el uso de disco se oculta por debajo de 1280px para hacer
  sitio); "Ilimitado"/"Generar" se muestran con `content: attr(title)`;
  los 9 lapices de `edit_server.php` llevan la clase `qemucp-edit-link` y
  un `<span class="u-hidden">` con "Edit" (los demas temas no cambian).
  Login en una sola columna con boton a todo el ancho.
- La barra superior mide 56px (no 40): el tema sobrescribe tambien
  `.app-header` (padding-top) y el `top` sticky de `.toolbar`.
- Temas: `web/css/src/themes/*.css` (default, dark, flat, vestia, qemucp).
  `default.min.css` se carga siempre y el tema elegido va encima. Se
  compilan a `web/css/themes/*.min.css` en el build del paquete
  (`build.js`, lightningcss con nesting y custom media). Los usuarios lo
  eligen en su perfil (`v-change-user-theme`); `v-list-sys-themes` los lista.
- Tema por defecto: PASO 2C de `install/qemucp_install.sh`, **solo en
  instalaciones nuevas** (relanzar no cambia el tema de un servidor que ya
  funciona). Fija `THEME` en `hestia.conf` (lo heredan los usuarios nuevos,
  que `v-add-user` crea con `THEME=''`) y el del admin. Si `qemucp` no
  existe (instalacion desde apt) cae a `flat`.
- Pruebas: bloque "tema" al final de `test/qemucp.bats`.
- Compilar en local (sin servidor): hay un Node en
  `~/Desarrollo/node-v24.21.0-darwin-arm64/bin`; `npm ci && node build.js`
  deja `web/css/themes/*.min.css` (ignorados por git). Ojo: `npm ci`
  activa husky (`core.hooksPath=.husky/_`) y los commits fallan si `node`
  no esta en el PATH; deshacerlo con `git config --unset core.hooksPath`. Lo que el tema no
  debe perder (revisado): foco de teclado del menu (`.main-menu-item.focus`)
  y de las filas (`.units-table-row.focus`, en la primera celda porque el
  borde de una fila de tabla no se pinta), `.button-danger` en rojo, y el
  `!important` de `.u-unstyled-button` en los botones "Generar".
- Gestor de archivos (FileGator, `/fm`): es otra aplicacion y **los temas
  del panel no le llegan**. Lleva su propio CSS,
  `install/deb/filemanager/filegator/dist/css/qemucp-fm.css`, enlazado en
  `configuration.php` (add_to_head) tras `hst-custom.css`. Barra marino
  porque el logo es blanco y sobre la barra gris de HestiaCP no se veia.
  Solo llega al instalar el gestor (`v-add-sys-filemanager`) o al
  actualizarlo: los servidores ya instalados necesitan reinstalarlo.
- Traducciones: `web/locale/es/LC_MESSAGES/hestiacp.mo` (solo el `.mo`).

## Textos para usuarios no tecnicos

Objetivo: que el panel hable el idioma de un usuario normal, no el de un
sysadmin. Hecho hasta ahora:

- "Plantilla Backend" -> **"Version de PHP"** en editar dominio web, crear
  plan y editar plan (y en sus mensajes de error). Las opciones se ven
  como "PHP 8.3" / "Por defecto del servidor" con `qemucp_backend_label()`
  (`web/inc/main.php`); el `value` sigue siendo `PHP-8_3`/`default`, asi
  que no cambia nada en los datos. Se quito la etiqueta "PHP-FPM".

Como hacerlo con otros textos:

- En la plantilla, usar un msgid en ingles claro (`_("PHP Version")`) en
  lugar de cambiar la traduccion de uno existente que se use en mas sitios.
- Las traducciones van en `install/qemucp-textos.py` (diccionario
  `TEXTOS`), que reescribe `web/locale/es/LC_MESSAGES/hestiacp.mo` (el
  repo no trae `.po`). **Relanzarlo tras sincronizar locales de upstream**:
  el `.mo` de upstream no trae estos textos. Lo comprueba `test/qemucp.bats`.

## Marca: QemuCP, nunca qemugen

Todo lo que ve el usuario dice QemuCP. Logos e iconos en `web/images/`:
`logo.svg`/`logo-header.svg` (logo apaisado, blanco), `logo.png` y
`logo-full.png` (el mismo en PNG), `favicon.png` (64px),
`apple-touch-icon.png` (180px) y `web/favicon.ico` (16/32/48): simbolo de
QemuCP sobre cuadrado marino redondeado, sacado de `logo.svg`. Correo:
`soporte@qemucp.com`. Lo comprueba `test/qemucp.bats`.

Lo que **no** se cambia: las URLs `github.com/qemugen/qemucp` y
`raw.githubusercontent.com/qemugen/qemucp/...` (es donde vive el
repositorio; cambiarlas rompe instalar y actualizar) y el nombre del
servidor de produccion qemugen.com.

## APLICACIONES (instalador + gestor de WordPress, antes "WP-TOOL")

Pestana **APLICACIONES** del menu principal (`web/templates/includes/panel.php`,
bloque "QemuCP WP-TOOL") -> `web/list/wp/`. Arriba, el catalogo del
instalador de aplicaciones (mismo descubrimiento que `web/add/webapp`: un
`*Setup.php` por carpeta en `web/src/app/WebApp/Installers/`) con un selector
de web; "Instalar" lleva a `/add/webapp/?app=CARPETA&domain=...`. Abajo, "Tus
aplicaciones instaladas": WordPress detectados con acciones (`web/edit/wp/`,
con `verify_csrf`).

**El panel corre como `hestiaweb` y solo puede `sudo` a `bin/v-*`**: nada
de `exec("sudo -u usuario wp ...")`, `mkdir`, `tar` o `file_put_contents`
en /home desde PHP. Las acciones van por `bin/v-qemucp-wp USER ACTION
[DOMAIN]` (list, update, maintenance-on/off, flush-cache, backup), que usa
`user_exec` y el WP-CLI por usuario (`~/.wp-cli/wp`). Los instaladores usan
`$this->appcontext` (runWp, runPHP, createFile...), que hace lo mismo.

**Instaladores propios** (`WordPressOptimized`, `PrestaShopOptimized`):
heredan los oficiales (`extends WordPressSetup` / `PrestaShopSetup`) y solo
anaden ajustes. Antes extendian `Hestia\WebApp\Installers\BaseSetup`, que
no existe desde 1.10, y como la lista instancia todos los instaladores, la
pagina entera daba error. **Un instalador roto tumba la lista**: lo
comprueba `test/qemucp.bats`. La lista usa la carpeta (no el nombre visible)
para el logo y `?app=`.

**Performance Dashboard** (`/list/performance/`, solo admin, enlace en la
barra superior junto a Configuracion del servidor). La API
(`web/api/performance-stats/`) incluye `inc/main.php` y mira `userContext`
(antes `$_SESSION['role']`, que no existe); los servicios salen de
`v-list-sys-services`.

**Se perdieron al sincronizar HestiaCP 1.10.3** (la fusion se quedo con el
`panel.php` de upstream). Al fusionar una version nueva, conservar los
bloques QemuCP de `panel.php`; lo comprueba `test/qemucp.bats`.

## Lista de webs y panel de usuario (tema qemucp)

- Con el tema qemucp, `web/list/web/index.php` usa
  `templates/pages/list_web_qemucp.php` (`qemucp_theme_active()` en
  `inc/main.php`); con los demas temas sigue `list_web.php` **sin tocar**
  (igual que upstream). Lista sencilla: un `<details class="qemucp-site">`
  por web; al pulsarlo se despliega su panel de opciones con icono y texto
  agrupadas como en Plesk (Web, Archivos y datos, Correo y DNS,
  Estadisticas y registros; Suspender/Borrar abajo). Cada subdominio va
  justo debajo de su dominio y sangrado; `data-sort-name` = cadena desde el
  dominio raiz para que ordenar por nombre no rompa los grupos. Conserva
  `js-unit`, `js-unit-checkbox`, `shortcut-*` y `js-confirm-action` (orden,
  acciones masivas, atajos de teclado y confirmaciones del JS del panel).
- `panel.php`: franja "Estas gestionando la cuenta de X / Volver a tu
  cuenta" cuando un admin entra como usuario, solo con el tema qemucp.
- En los controladores, `$user` **ya va entrecomillado** (`quoteshellarg`
  en `inc/main.php`): no volver a pasarlo por `quoteshellarg`.

## Probar PHP sin servidor

No hay PHP en el Mac: `npx @php-wasm/cli` (PHP 8.5 en WebAssembly, del
proyecto WordPress Playground) sirve para `-l` y para ejecutar scripts que
lean el repo (sin `exec` de comandos `v-*`). `test/qemucp-local/instaladores.php`
carga todos los instaladores y simula las versiones optimizadas. Para ver
una plantilla real: definir `_()`, `tohtml()`, `$_SESSION` y los datos que
espera, e `include` la plantilla.
