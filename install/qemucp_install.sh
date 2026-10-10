#!/bin/bash
# =============================================================================
#  QemuCP - Instalador personalizado basado en HestiaCP
#  Compatible con: Ubuntu 24.04 LTS (limpio)
#
#  Uso:
#    bash qemucp_install.sh               pide la clave de acceso (no se ve)
#    QEMUCP_HOSTNAME=panel.tudominio.com QEMUCP_KEY='...' bash qemucp_install.sh
#                                         desatendido
#    bash qemucp_install.sh --set-pass    genera el hash de una clave nueva
#
#  Por defecto el panel se compila e instala desde NUESTRO fork, no desde
#  apt.hestiacp.com, y se bloquea con apt-mark hold. Para la via clasica:
#    QEMUCP_DESDE_APT=yes bash qemucp_install.sh
#
#  Es un unico fichero: los scripts auxiliares (hook de post-actualizacion,
#  limite de subdominios, cola de reinicios) van incrustados y se despliegan
#  en el PASO 0.
# =============================================================================


# ---------------------------------------------
#  VARIABLES DE CONFIGURACION
# ---------------------------------------------
BRAND_NAME="QemuCP"
# Logo desde el fork de GitHub (fiable). Fallback: zonasdnsprivadas.com
BRAND_LOGO="https://raw.githubusercontent.com/qemugen/qemucp/release/web/images/logo.png"
BRAND_LOGO_FALLBACK="https://zonasdnsprivadas.com/scripts/assets/img/logo.png"
ADMIN_EMAIL="soporte@qemugen.com"
ADMIN_PASS=$(cat /dev/urandom | tr -dc 'A-Za-z0-9' | head -c 24 || true)
TIMEZONE="Europe/Madrid"
HESTIA_LANG="es"  # Idioma del panel HestiaCP (NO confundir con locale del SO)
HESTIA_PORT="8083"

PHP_VERSIONS=("7.2" "7.3" "7.4" "8.0" "8.1" "8.2" "8.3" "8.4" "8.5")
# Permitir PHP legacy (5.6/7.0/7.1) si el cliente lo necesita para webs antiguas.
# ADVERTENCIA: estas versiones estan EOL y son un riesgo de seguridad.
# Para activar: ALLOW_LEGACY_PHP="yes" bash qemucp_install.sh
ALLOW_LEGACY_PHP="${ALLOW_LEGACY_PHP:-no}"

# ============================================================
# CLAVE DE ACCESO QEMUCP
# ============================================================
# Solo se guarda el HASH SHA-256 de la clave, nunca la clave: el fork es
# publico y antes estaba en claro aqui mismo.
#
# La clave ya no se pasa como argumento. Como argumento quedaba en el
# historial de shell y era visible en 'ps' mientras se instalaba. Ahora:
#   - interactivo:  bash qemucp_install.sh        (la pide sin mostrarla)
#   - desatendido:  QEMUCP_KEY='...' bash qemucp_install.sh
#
# Para cambiarla:  bash qemucp_install.sh --set-pass
# y sustituye la linea QEMUCP_KEY_HASH por la que imprime.
#
# La clave se genero al azar (24 caracteres) y no esta en el repositorio:
# solo su hash. La anterior estuvo en claro en el repo publico y ya no vale.
QEMUCP_KEY_HASH="02db216724a954d26fdc08e7b304491a4529886180eb3c6b4ddcb82051e0e04f"

_qemucp_hash() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

_qemucp_rechazo() {
    echo ""
    echo "  +-------------------------------------------+"
    echo "  |      QemuCP - Acceso Restringido          |"
    echo "  |                                           |"
    echo "  |  Este software es propiedad de QemuGen.  |"
    echo "  |  Contacta: soporte@qemugen.com            |"
    echo "  +-------------------------------------------+"
    echo ""
    exit 1
}

# --set-pass: genera el hash de una clave nueva. No instala nada.
if [[ "${1:-}" == "--set-pass" ]]; then
    echo ""
    read -rsp "  Clave nueva: " _P1; echo ""
    read -rsp "  Repitela:    " _P2; echo ""
    if [[ -z "$_P1" ]]; then echo "  Vacia, cancelado."; exit 1; fi
    if [[ "$_P1" != "$_P2" ]]; then echo "  No coinciden."; exit 1; fi
    if [[ ${#_P1} -lt 16 ]]; then
        echo "  Usa al menos 16 caracteres: el hash esta en un repositorio"
        echo "  publico y una clave corta se puede sacar por fuerza bruta."
        exit 1
    fi
    echo ""
    echo "  Sustituye la linea QEMUCP_KEY_HASH del script por esta:"
    echo ""
    echo "QEMUCP_KEY_HASH=\"$(_qemucp_hash "$_P1")\""
    echo ""
    unset _P1 _P2
    exit 0
fi

if [[ -n "${QEMUCP_KEY:-}" ]]; then
    # Desatendido, por variable de entorno
    [[ "$(_qemucp_hash "$QEMUCP_KEY")" == "$QEMUCP_KEY_HASH" ]] || _qemucp_rechazo
elif [[ -n "${1:-}" ]]; then
    # Compatibilidad con la forma antigua: funciona, pero la clave ya esta
    # en el historial. Se avisa y se dice como quitarla de ahi.
    [[ "$(_qemucp_hash "$1")" == "$QEMUCP_KEY_HASH" ]] || _qemucp_rechazo
    echo ""
    echo "  AVISO: has pasado la clave como argumento y ha quedado en tu"
    echo "  historial de shell. La proxima vez lanza el script sin argumentos"
    echo "  y te la pedira sin mostrarla."
    echo "  Para quitarla del historial al terminar:"
    echo "      history -d \$(history | grep -m1 'qemucp_install' | awk '{print \$1}')"
    echo ""
    sleep 3
else
    _INTENTOS=0
    while true; do
        if ! read -rsp "  Clave de acceso QemuCP: " _ENTRADA; then
            echo ""
            echo "  No hay terminal para pedir la clave."
            echo "  En modo desatendido:  QEMUCP_KEY='...' bash $0"
            exit 1
        fi
        echo ""
        [[ "$(_qemucp_hash "$_ENTRADA")" == "$QEMUCP_KEY_HASH" ]] && break
        _INTENTOS=$((_INTENTOS+1))
        [[ "$_INTENTOS" -ge 3 ]] && _qemucp_rechazo
        echo "  Clave incorrecta. Te quedan $((3-_INTENTOS))."
        sleep 2
    done
fi
unset _ENTRADA QEMUCP_KEY _INTENTOS

set -euo pipefail

# Si el script muere, decir EXACTAMENTE en que linea y con que comando.
# Sin esto un fallo (p.ej. variable no definida con set -u) corta la
# instalacion sin dejar rastro, que es lo que ocurrio en produccion.
# Marca de progreso: si el script muere, sabemos donde iba.
QEMUCP_PASO="inicio"

# trap EXIT captura TODO, incluido 'unbound variable' de set -u (que ERR no
# atrapa porque bash sale antes). Sin esto la instalacion se corta en
# silencio, como ocurrio en produccion con HESTIA_INSTALL_VER.
trap 'RC=$?
if [ $RC -ne 0 ]; then
    echo ""
    echo "==========================================================="
    echo "  LA INSTALACION SE HA DETENIDO"
    echo "==========================================================="
    echo "  Ultimo paso completado: ${QEMUCP_PASO}"
    echo "  Codigo de salida:       $RC"
    echo ""
    echo "  El panel puede estar instalado pero SIN optimizaciones."
    echo "  Relanza este script: detecta la instalacion existente y"
    echo "  aplica solo los pasos que falten."
    echo ""
fi' EXIT

# Evitar ventanas interactivas durante apt (GRUB, sshd, etc)
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
# Generar el locale es_ES.UTF-8 ANTES de exportarlo (si no, apt/perl dan
# warnings "locale not supported" y aparece el LC_MESSAGES undefined).
if ! locale -a 2>/dev/null | grep -qi "es_ES.utf8\|es_ES.UTF-8"; then
    apt-get install -y -qq locales 2>/dev/null || true
    locale-gen es_ES.UTF-8 2>/dev/null || true
fi
# Exportar solo si el locale existe; si no, usar C.UTF-8 (siempre disponible)
if locale -a 2>/dev/null | grep -qi "es_ES.utf8\|es_ES.UTF-8"; then
    export LANG=es_ES.UTF-8
    export LC_ALL=es_ES.UTF-8
    export LANGUAGE=es_ES.UTF-8
else
    export LANG=C.UTF-8
    export LC_ALL=C.UTF-8
fi

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[!!]${NC} $1"; exit 1; }
info()   { echo -e "${BLUE}[..]${NC} $1"; }
header() {
    QEMUCP_PASO="$1" echo -e "\n${BLUE}======================================${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}======================================${NC}\n"; }

# ---------------------------------------------
#  COMPROBACIONES PREVIAS
# ---------------------------------------------
header "QemuCP Installer - Comprobaciones previas"

[[ $EUID -ne 0 ]] && error "Ejecuta este script como root: sudo bash qemucp_install.sh"

OS=$(lsb_release -rs 2>/dev/null || echo "0")
[[ "$OS" != "24.04" ]] && warn "Optimizado para Ubuntu 24.04. Continua bajo tu responsabilidad."

RAM=$(free -m | awk '/^Mem:/{print $2}')
[[ $RAM -lt 1024 ]] && warn "Se recomienda minimo 1GB de RAM. Tienes ${RAM}MB."

log "Sistema: Ubuntu $OS"
log "RAM: ${RAM}MB"

# ---------------------------------------------
#  SOLICITAR HOSTNAME OBLIGATORIO
# ---------------------------------------------
echo ""
echo -e "${BLUE}  Configuracion del servidor${NC}"
echo -e "${BLUE}--------------------------------------${NC}"
_hostname_valido() {
    echo "$1" | grep -qP '^[a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?)+$'
}

if [[ -n "${QEMUCP_HOSTNAME:-}" ]]; then
    # Desatendido: QEMUCP_HOSTNAME=panel.tudominio.com
    HOSTNAME="${QEMUCP_HOSTNAME,,}"
    HOSTNAME="${HOSTNAME//[[:space:]]/}"
    _hostname_valido "$HOSTNAME" || error "QEMUCP_HOSTNAME no es un dominio valido: $HOSTNAME"
else
    while true; do
        echo -ne "  ${YELLOW}Introduce el hostname del panel${NC} (ej: panel.tudominio.com): "
        # Sin terminal, read devuelve 1 y set -e abortaria sin explicar nada
        if ! read -r HOSTNAME; then
            echo ""
            error "No hay terminal para pedir el hostname. En desatendido usa:
  QEMUCP_HOSTNAME=panel.tudominio.com QEMUCP_KEY='...' bash $0"
        fi
        # Minusculas y sin espacios. No se usa xargs: con una comilla en la
        # entrada falla ("unmatched quote") y con pipefail aborta el script.
        HOSTNAME="${HOSTNAME,,}"
        HOSTNAME="${HOSTNAME//[[:space:]]/}"

        if [[ -z "$HOSTNAME" ]]; then
            echo -e "  ${RED}[!!]${NC} El hostname no puede estar vacio."
            continue
        fi

        if ! _hostname_valido "$HOSTNAME"; then
            echo -e "  ${RED}[!!]${NC} Formato invalido. Usa un dominio completo como: panel.tudominio.com"
            continue
        fi

        echo -ne "  ${YELLOW}Confirma el hostname${NC}: $HOSTNAME [s/n]: "
        CONFIRM=""
        read -r CONFIRM || true
        [[ "$CONFIRM" =~ ^[sS]$ ]] && break
    done
fi

echo ""
log "Hostname configurado: $HOSTNAME"

# ---------------------------------------------
#  PASO 0: DESPLEGAR SCRIPTS AUXILIARES
# ---------------------------------------------
header "PASO 0: Desplegando scripts auxiliares"

# Van incrustados en este fichero: la instalacion no depende de que GitHub
# responda a mitad del proceso, ni hay que acordarse de dejarlos en /root.
AUX_DIR="/opt/qemucp"
mkdir -p "$AUX_DIR"
cat > "$AUX_DIR/instalar-hook.sh" << 'QEMUCP_EMBED_HOOK'
#!/bin/bash
# ============================================================================
#  QemuCP - Hook de post-actualizacion (RUTA CORRECTA)
#
#  EL PROBLEMA QUE CORRIGE:
#    Hasta ahora los parches de QemuCP se registraban en
#        /usr/local/hestia/data/hooks/post_update.sh
#    que HestiaCP NO EJECUTA NUNCA. El unico hook real es
#        /etc/hestiacp/hooks/post_install.sh
#    invocado al final de /var/lib/dpkg/info/hestia.postinst.
#    Consecuencia: ningun parche se reaplicaba tras un 'apt upgrade', y el
#    session.save_path duplicado reaparecia en cada actualizacion.
#
#  Reaplica, en este orden:
#    1. File Manager: $_SESSION["root"] indefinido
#    2. Plantillas php-fpm: session.save_path de fichero duplicado
#    3. Limite de subdominios (WEB_SUBDOMAINS)
#    4. Regeneracion de pools si se tocaron plantillas (el postinst ya hizo
#       upgrade_rebuild_users ANTES de llegar al hook, con las plantillas sin
#       parchear, asi que hay que rehacerlo)
#    5. Cola de reinicios (crons de hestiaweb)
#
#  Uso:
#    bash instalar-hook.sh            instala el hook
#    bash instalar-hook.sh --probar   lo ejecuta ahora para ver que hace
#    bash instalar-hook.sh --estado   solo informa, no cambia nada
# ============================================================================

set -u
HESTIA="${HESTIA:-/usr/local/hestia}"
HOOK_DIR="/etc/hestiacp/hooks"
HOOK="$HOOK_DIR/post_install.sh"
HOOK_VIEJO="$HESTIA/data/hooks/post_update.sh"
MODO="instalar"
[ "${1:-}" = "--probar" ] && MODO="probar"
[ "${1:-}" = "--estado" ] && MODO="estado"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}OK${NC}     $1"; }
bad()  { echo -e "  ${RED}FALLO${NC}  $1"; }
warn() { echo -e "  ${YELLOW}AVISO${NC}  $1"; }

echo "============================================================"
echo " QemuCP - hook de post-actualizacion"
echo "============================================================"
echo ""

[ -d "$HESTIA/bin" ] || { bad "No parece una instalacion de QemuCP en $HESTIA"; exit 1; }

# ------------------------------------------------------------------ estado
echo "--- Estado actual ---"
if [ -e "$HOOK" ]; then
    if grep -q "QemuCP" "$HOOK" 2>/dev/null; then
        ok "$HOOK instalado"
    else
        warn "$HOOK existe pero no es de QemuCP (se conservara y se anadira al final)"
    fi
else
    bad "$HOOK NO existe: los parches no se reaplican tras un apt upgrade"
fi
if [ -e "$HOOK_VIEJO" ]; then
    warn "existe el hook antiguo en una ruta que HestiaCP no ejecuta:"
    warn "  $HOOK_VIEJO"
fi
# Confirmar que el paquete realmente invoca este hook en ESTA version
POSTINST="/var/lib/dpkg/info/hestia.postinst"
if [ -f "$POSTINST" ]; then
    if grep -q "$HOOK" "$POSTINST" 2>/dev/null; then
        ok "el postinst del paquete hestia invoca $HOOK"
    else
        bad "el postinst instalado NO menciona $HOOK"
        warn "revisa: grep hooks $POSTINST"
    fi
else
    warn "no se encuentra $POSTINST (no se puede confirmar la invocacion)"
fi

if [ "$MODO" = "estado" ]; then
    echo ""
    echo "Para instalarlo:  bash $0"
    exit 0
fi

# ---------------------------------------------------------------- instalar
if [ "$MODO" = "instalar" ]; then
    echo ""
    echo "--- Instalando ---"
    mkdir -p "$HOOK_DIR" "$HESTIA/data/qemucp"

    # Si ya hay un hook de QemuCP, se reemplaza su bloque; si hay uno ajeno,
    # se conserva y el bloque de QemuCP se anade detras.
    if [ -e "$HOOK" ] && grep -q "QemuCP-BLOQUE-INICIO" "$HOOK" 2>/dev/null; then
        cp -a "$HOOK" "$HOOK.bak-$(date +%Y%m%d-%H%M%S)"
        sed -i '/# QemuCP-BLOQUE-INICIO/,/# QemuCP-BLOQUE-FIN/d' "$HOOK"
        ok "bloque anterior de QemuCP retirado (backup guardado)"
    fi
    if [ ! -e "$HOOK" ]; then
        printf '#!/bin/bash\n' > "$HOOK"
        ok "hook creado con shebang"
    elif ! head -1 "$HOOK" | grep -q '^#!'; then
        # Sin shebang el postinst lo ejecuta con /bin/sh y los bashismos fallan
        sed -i '1i #!/bin/bash' "$HOOK"
        warn "al hook le faltaba el shebang, anadido"
    fi

    cat >> "$HOOK" << 'HOOKEOF'

# QemuCP-BLOQUE-INICIO  (no editar a mano: lo regenera instalar-hook.sh)
# Lo ejecuta el postinst del paquete hestia al final de cada instalacion o
# actualizacion. El paquete sobrescribe bin/, func/, web/ y las plantillas,
# asi que aqui se reaplica todo lo propio de QemuCP.
{
    H=/usr/local/hestia
    echo "=== $(date '+%F %T') QemuCP post_install ==="

    # 0. Marca y personalizaciones de QemuCP. Va PRIMERO porque el rebrand
    #    reescribe plantillas de php-fpm y nginx, y los parches de abajo
    #    tienen que aplicarse sobre el resultado final.
    #
    #    Si el panel se instalo desde NUESTRO fork, el paquete ya trae la
    #    marca, WP-TOOL y el dashboard de rendimiento: no hay nada que
    #    injertar. Y hacerlo seria peligroso, porque el rebrand descarga de
    #    la rama release EN ESE MOMENTO, que puede ir por delante del paquete
    #    instalado, y mezclaria PHP de dos versiones (el bucle de login).
    ORIGEN=$(cut -d' ' -f1 "$H/conf/qemucp-origen" 2>/dev/null || true)
    REBRAND_URL="https://raw.githubusercontent.com/qemugen/qemucp/release/install/qemucp-rebrand.sh"
    if [ "$ORIGEN" = "fork" ]; then
        echo "  marca: el paquete ya es nuestro fork, no se injerta nada"
    elif [ -x "$H/data/qemucp/qemucp-rebrand.sh" ]; then
        bash "$H/data/qemucp/qemucp-rebrand.sh" >/dev/null 2>&1 \
            && echo "  marca QemuCP reaplicada (copia local)" \
            || echo "  AVISO: fallo el rebrand local"
    elif wget -q --timeout=30 "${REBRAND_URL}?cb=$(date +%s)" -O /tmp/qemucp-rebrand.sh 2>/dev/null; then
        bash /tmp/qemucp-rebrand.sh >/dev/null 2>&1 \
            && echo "  marca QemuCP reaplicada (descargada)" \
            || echo "  AVISO: fallo el rebrand descargado"
        rm -f /tmp/qemucp-rebrand.sh
    else
        echo "  AVISO: no se pudo reaplicar la marca (sin copia local ni red)"
    fi

    # 1. File Manager: HestiaAuth.php lee $_SESSION["root"], que el panel
    #    nunca define. Con PHP 8.x rompe la respuesta del gestor de ficheros
    #    y el usuario ve "Error desconocido" al entrar en cualquier carpeta.
    FM="$H/web/fm/backend/Services/Auth/Adapters/HestiaAuth.php"
    if [ -f "$FM" ] && grep -q '\$_SESSION\["look"\] == \$_SESSION\["root"\]' "$FM" 2>/dev/null; then
        sed -i 's|\$_SESSION\["look"\] == \$_SESSION\["root"\] &&|$_SESSION["look"] == ($_SESSION["root"] ?? "") \&\&|' "$FM"
        echo "  File Manager parcheado"
    fi

    # 2. Plantillas php-fpm: deben llevar el bloque de QemuCP (sesiones en
    #    Redis, OPcache, limites) y UNA sola linea session.save_path.
    #    Dos situaciones posibles tras una actualizacion:
    #    a) La plantilla perdio el bloque. Pasa si una version activa
    #       UPGRADE_UPDATE_WEB_TEMPLATES: v-update-web-templates regenera los
    #       PHP-*.tpl desde multiphp.tpl. Las sesiones volverian a fichero.
    #    b) Tiene el bloque Y la linea de fichero de HestiaCP: dos
    #       session.save_path, PHP usa la de fichero y revienta la sesion en
    #       PrestaShop, Joomla y Moodle.
    #    c) Tiene VARIOS bloques: el instalador antiguo anadia uno nuevo cada
    #       vez que se relanzaba, porque su llave nunca coincidia.
    #    Correcta = exactamente un bloque y ninguna linea de fichero. Si no lo
    #    esta, se quitan todos los bloques y la linea de fichero y se pone uno.
    MARCA='; -- QemuCP: Optimizaciones de rendimiento --'
    TOCADAS=0
    for T in "$H"/data/templates/web/php-fpm/*.tpl; do
        [ -f "$T" ] || continue
        NB=$(grep -c "^$MARCA\$" "$T" 2>/dev/null || true)
        NF=$(grep -c '^php_admin_value\[session.save_path\] = /home/' "$T" 2>/dev/null || true)
        NC=$(grep -c '^php_admin_value\[opcache.save_comments\] = 1$' "$T" 2>/dev/null || true)
        # Correcta: un bloque completo (marca y cierre) y ninguna linea de fichero
        [ "${NB:-0}" -eq 1 ] && [ "${NC:-0}" -eq 1 ] && [ "${NF:-0}" -eq 0 ] && continue
        # Un bloque sin su linea de cierre haria que el borrado por rango se
        # llevara el resto del fichero: en ese caso no se toca y se avisa.
        if [ "${NB:-0}" -gt "${NC:-0}" ]; then
            echo "  AVISO: $(basename "$T") tiene un bloque QemuCP incompleto, revisalo a mano"
            continue
        fi
        sed -i "/^$MARCA\$/,/^php_admin_value\[opcache.save_comments\] = 1\$/d" "$T"
        sed -i '/^php_admin_value\[session.save_path\] = \/home\//d' "$T"
        # quitar lineas en blanco que hayan quedado al final
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$T"
        cat >> "$T" << 'QTPLEOF'

; -- QemuCP: Optimizaciones de rendimiento --
; Memoria y uploads
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 256M
php_admin_value[post_max_size] = 256M
php_admin_value[max_file_uploads] = 100
; Ejecucion
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_time] = 300
php_admin_value[max_input_vars] = 10000
; Seguridad
php_flag[display_errors] = off
php_admin_flag[log_errors] = on
; Sesiones via Redis
php_admin_value[session.save_handler] = redis
php_admin_value[session.save_path] = "tcp://127.0.0.1:6379?timeout=1&prefix=SESS_&database=1"
php_admin_value[session.gc_maxlifetime] = 1440
php_admin_value[session.cookie_httponly] = 1
php_admin_value[session.cookie_secure] = 1
; SOAP (PrestaShop)
php_value[soap.wsdl_cache_enabled] = 1
php_value[soap.wsdl_cache_ttl] = 86400
; OPcache
php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 256
php_admin_value[opcache.interned_strings_buffer] = 32
php_admin_value[opcache.max_accelerated_files] = 30000
php_admin_value[opcache.validate_timestamps] = 1
php_admin_value[opcache.revalidate_freq] = 60
php_admin_value[opcache.save_comments] = 1
QTPLEOF
        TOCADAS=$((TOCADAS+1))
    done
    [ "$TOCADAS" -gt 0 ] && echo "  $TOCADAS plantilla(s) php-fpm corregidas"

    # 3. Limite de subdominios: el parche vive en bin/ y func/, que el
    #    paquete acaba de sobrescribir.
    if [ -x "$H/data/qemucp/parche-subdominios.sh" ]; then
        "$H/data/qemucp/parche-subdominios.sh" >> /var/log/qemucp-subdominios.log 2>&1 \
            && echo "  limite de subdominios reaplicado" \
            || echo "  AVISO: fallo al reaplicar el limite de subdominios"
    fi

    # 4. Si se tocaron plantillas hay que regenerar los pools: el postinst
    #    ejecuto upgrade_rebuild_users ANTES de llamar a este hook, es decir
    #    con las plantillas aun sin parchear.
    if [ "$TOCADAS" -gt 0 ]; then
        for U in $(ls "$H/data/users/" 2>/dev/null); do
            [ -f "$H/data/users/$U/web.conf" ] || continue
            "$H/bin/v-rebuild-web-domains" "$U" no >/dev/null 2>&1 || true
        done
        for V in $(ls /etc/php/ 2>/dev/null); do
            systemctl reload "php${V}-fpm" >/dev/null 2>&1 || true
        done
        echo "  pools php-fpm regenerados con las plantillas corregidas"
    fi

    # 5. Cola de reinicios: sin el cron de hestiaweb, los dominios nuevos no
    #    resuelven hasta que se guarda la zona a mano.
    if [ -x "$H/data/qemucp/arreglar-crons.sh" ]; then
        "$H/data/qemucp/arreglar-crons.sh" >> /var/log/qemucp-crons.log 2>&1 \
            && echo "  cola de reinicios verificada" \
            || echo "  AVISO: fallo al verificar la cola de reinicios"
    fi

    echo "=== fin QemuCP post_install ==="
} >> /var/log/qemucp-post-install.log 2>&1
# QemuCP-BLOQUE-FIN
HOOKEOF

    chmod 755 "$HOOK"
    ok "bloque de QemuCP instalado en $HOOK"

    if ! bash -n "$HOOK" 2>/dev/null; then
        bad "el hook tiene un error de sintaxis, se restaura el backup"
        ULTIMO=$(ls -1t "$HOOK".bak-* 2>/dev/null | head -1)
        [ -n "$ULTIMO" ] && cp -a "$ULTIMO" "$HOOK"
        exit 1
    fi
    ok "sintaxis del hook correcta"

    # Los scripts a los que llama el hook tienen que estar donde los busca
    echo ""
    echo "--- Scripts que invoca el hook ---"
    # El rebrand se descarga si no esta en local, pero tener la copia evita
    # depender de la red justo despues de un apt upgrade.
    if [ ! -x "$HESTIA/data/qemucp/qemucp-rebrand.sh" ]; then
        if [ -f /root/qemucp-rebrand.sh ]; then
            cp -a /root/qemucp-rebrand.sh "$HESTIA/data/qemucp/"
            chmod +x "$HESTIA/data/qemucp/qemucp-rebrand.sh"
            ok "qemucp-rebrand.sh copiado desde /root"
        else
            warn "sin copia local de qemucp-rebrand.sh: el hook lo descargara"
        fi
    else
        ok "qemucp-rebrand.sh presente"
    fi
    for S in parche-subdominios.sh arreglar-crons.sh; do
        if [ -x "$HESTIA/data/qemucp/$S" ]; then
            ok "$S presente"
        else
            warn "falta $HESTIA/data/qemucp/$S"
            warn "  el hook lo saltara. Instalalo con:"
            warn "  bash /root/$S"
        fi
    done

    # Retirar el hook antiguo para que nadie confie en el
    if [ -e "$HOOK_VIEJO" ]; then
        mv "$HOOK_VIEJO" "$HOOK_VIEJO.NO-SE-EJECUTA-NUNCA"
        warn "hook antiguo renombrado a $(basename "$HOOK_VIEJO").NO-SE-EJECUTA-NUNCA"
    fi
fi

# ------------------------------------------------------------------ probar
if [ "$MODO" = "probar" ] || [ "$MODO" = "instalar" ]; then
    echo ""
    echo "--- Ejecutando el hook ahora (como lo haria un apt upgrade) ---"
    if [ -x "$HOOK" ]; then
        "$HOOK"
        echo "  salida registrada en /var/log/qemucp-post-install.log:"
        tail -12 /var/log/qemucp-post-install.log 2>/dev/null | sed 's/^/    /'
    else
        bad "$HOOK no es ejecutable"
    fi
fi

echo ""
echo "============================================================"
echo " Hecho. A partir de ahora, cada 'apt upgrade' del paquete"
echo " hestia reaplicara los parches solo."
echo "============================================================"
echo ""
echo "Comprobarlo de verdad, forzando una reinstalacion del paquete:"
echo "  apt-get install --reinstall -y hestia"
echo "  grep -c count_web_domains_split /usr/local/hestia/func/main.sh   # debe ser > 0"
echo "  tail -20 /var/log/qemucp-post-install.log"
exit 0
QEMUCP_EMBED_HOOK
cat > "$AUX_DIR/parche-subdominios.sh" << 'QEMUCP_EMBED_SUB'
#!/bin/bash
# ============================================================================
#  QemuCP - Limite de SUBDOMINIOS separado del de dominios (estilo cPanel)
#
#  Problema que resuelve:
#    HestiaCP cuenta CUALQUIER dominio web en WEB_DOMAINS. Un subdominio
#    (tienda.cliente.com) gasta el mismo cupo que un dominio adicional
#    (otrocliente.es), asi que no se pueden hacer planes con 0 dominios
#    adicionales y N subdominios como en cPanel (maxaddon / maxsub).
#
#  Que hace:
#    Anade la clave WEB_SUBDOMAINS a los paquetes. Un dominio nuevo cuenta
#    contra WEB_SUBDOMAINS si es X.DOMINIO de un dominio que YA aloja el
#    mismo usuario; contra WEB_DOMAINS en cualquier otro caso.
#
#  Compatibilidad:
#    El cambio es por paquete. Mientras un paquete no tenga WEB_SUBDOMAINS
#    con valor, sus usuarios se comportan EXACTAMENTE como ahora. Ningun
#    cliente gana ni pierde cupo hasta que tu edites su paquete.
#
#  Uso:
#    bash parche-subdominios.sh                 aplica el parche
#    bash parche-subdominios.sh --revertir      deshace desde el backup
#
#  Despues de aplicarlo, para cada paquete que quieras pasar al esquema
#  cPanel (ejemplo: 1 dominio, 10 subdominios):
#    v-change-user-package ... no hace falta, se hace desde el panel:
#    Paquetes -> editar -> "Web Domains" = 1 y "Web Subdomains" = 10
#    y guardar (el panel propaga el paquete a sus usuarios).
#  O por SSH:
#    sed -i "/^WEB_DOMAINS=/a WEB_SUBDOMAINS='10'" /usr/local/hestia/data/packages/PLAN.pkg
#    v-update-user-package PLAN
# ============================================================================

set -u
HESTIA="${HESTIA:-/usr/local/hestia}"
BACKUP="/root/qemucp-subdominios-backup-$(date +%Y%m%d-%H%M%S)"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}OK${NC}   $1"; }
bad()  { echo -e "  ${RED}ERROR${NC} $1"; }
warn() { echo -e "  ${YELLOW}AVISO${NC} $1"; }

FICHEROS="func/main.sh bin/v-add-web-domain bin/v-add-domain bin/v-add-user \
bin/v-add-user-package bin/v-change-user-package bin/v-update-user-counters \
bin/v-list-user bin/v-list-user-package bin/v-list-user-packages \
web/add/package/index.php web/edit/package/index.php \
web/templates/pages/add_package.php web/templates/pages/edit_package.php"

# ---------------------------------------------------------------- revertir
if [ "${1:-}" = "--revertir" ]; then
    # El PRIMER backup es el unico que contiene los ficheros sin parchear.
    # Si se cogiera el ultimo se restauraria una version ya parcheada.
    PRIMERO=$(ls -1d /root/qemucp-subdominios-backup-* 2>/dev/null | head -1)
    [ -z "$PRIMERO" ] && { bad "No hay backup que restaurar"; exit 1; }
    if grep -q "count_web_domains_split" "$PRIMERO/func/main.sh" 2>/dev/null; then
        bad "El backup $PRIMERO ya contiene el parche: no serviria para revertir."
        bad "Restaura func/main.sh, bin/v-add-web-domain, bin/v-change-user-package,"
        bad "bin/v-update-user-counters y los 4 ficheros de web/ desde el paquete"
        bad "oficial: apt-get install --reinstall hestia"
        exit 1
    fi
    echo "Restaurando desde $PRIMERO"
    for F in $FICHEROS; do
        [ -f "$PRIMERO/$F" ] && cp -a "$PRIMERO/$F" "$HESTIA/$F" && ok "$F"
    done
    find "$HESTIA/bin" "$HESTIA/func" "$HESTIA/web" \
        \( -name "*.rej" -o -name "*.orig" \) -delete 2>/dev/null
    systemctl restart hestia 2>/dev/null
    echo "Revertido."
    exit 0
fi

# ----------------------------------------------------------------- --listar
# Estado de dominios y subdominios de todos los usuarios, con su limite.
if [ "${1:-}" = "--listar" ]; then
    if ! grep -q "count_web_domains_split" "$HESTIA/func/main.sh" 2>/dev/null; then
        bad "El parche no esta aplicado. Ejecuta primero: bash $0"
        exit 1
    fi
    FN=$(mktemp /tmp/qemucp-fn.XXXXXX.sh)
    sed -n '/^count_web_domains_split()/,/^}/p' "$HESTIA/func/main.sh" > "$FN"
    # shellcheck disable=SC1090
    . "$FN"; rm -f "$FN"
    printf "%-16s %-12s %14s %16s   %s\n" USUARIO PLAN DOMINIOS SUBDOMINIOS ESQUEMA
    printf "%-16s %-12s %14s %16s   %s\n" ---------------- ------------ -------------- ---------------- -------
    for UD in "$HESTIA"/data/users/*/; do
        [ -d "$UD" ] || continue
        U=$(basename "$UD")
        [ -f "$UD/web.conf" ] || continue
        S=$(count_web_domains_split "$UD/web.conf")
        USA_D=$(echo "$S" | cut -f1 -d' '); USA_S=$(echo "$S" | cut -f2 -d' ')
        PL=$(grep -m1 "^PACKAGE=" "$UD/user.conf" 2>/dev/null | cut -f2 -d\')
        LD=$(grep -m1 "^WEB_DOMAINS=" "$UD/user.conf" 2>/dev/null | cut -f2 -d\')
        LS=$(grep -m1 "^WEB_SUBDOMAINS=" "$UD/user.conf" 2>/dev/null | cut -f2 -d\')
        if [ -n "$LS" ]; then
            ESQ="separado"
            TOTD="$USA_D/$LD"; TOTS="$USA_S/$LS"
        else
            ESQ="heredado"
            # En el esquema heredado el limite es conjunto
            TOTD="$USA_D"; TOTS="$USA_S"
            [ -n "$LD" ] && TOTD="$USA_D (cupo conjunto $((USA_D+USA_S))/$LD)"
        fi
        printf "%-16s %-12s %14s %16s   %s\n" "$U" "${PL:-?}" "$TOTD" "$TOTS" "$ESQ"
    done
    echo ""
    echo "heredado = los subdominios gastan cupo de dominios (HestiaCP de siempre)"
    echo "separado = cada uno con su limite (como cPanel)"
    echo ""
    echo "Cambiar un plan:     bash $0 --plan PLAN DOMINIOS SUBDOMINIOS"
    echo "Cambiar un usuario:  bash $0 --usuario USUARIO DOMINIOS SUBDOMINIOS"
    exit 0
fi

# ---------------------------------------------------------------- --usuario
# Limites de UN usuario concreto, sin tocar su plan ni a los demas.
if [ "${1:-}" = "--usuario" ]; then
    USU="${2:-}"; NDOM="${3:-}"; NSUB="${4:-}"
    UC="$HESTIA/data/users/$USU/user.conf"
    if [ -z "$USU" ] || [ -z "$NDOM" ] || [ -z "$NSUB" ]; then
        echo "Uso: bash $0 --usuario USUARIO DOMINIOS SUBDOMINIOS"
        echo ""
        echo "  DOMINIOS     dominios de nivel superior, INCLUIDO el principal."
        echo "  SUBDOMINIOS  numero, o 'unlimited'."
        echo ""
        echo "Afecta solo a este usuario. Lo escribe en su user.conf, por encima"
        echo "de lo que diga su plan."
        exit 1
    fi
    [ -f "$UC" ] || { bad "No existe el usuario '$USU'"; exit 1; }
    if ! grep -q "count_web_domains_split" "$HESTIA/func/main.sh" 2>/dev/null; then
        bad "El parche no esta aplicado. Ejecuta primero: bash $0"
        exit 1
    fi
    case "$NDOM" in ''|*[!0-9]*) bad "DOMINIOS debe ser un numero"; exit 1 ;; esac
    [ "$NDOM" -lt 1 ] && { bad "DOMINIOS debe ser 1 o mas: el principal tambien cuenta"; exit 1; }
    if [ "$NSUB" != "unlimited" ]; then
        case "$NSUB" in ''|*[!0-9]*) bad "SUBDOMINIOS debe ser un numero o 'unlimited'"; exit 1 ;; esac
    fi

    cp -a "$UC" "$UC.bak-$(date +%Y%m%d-%H%M%S)"
    sed -i "/^WEB_SUBDOMAINS=/d" "$UC"
    sed -i "s|^WEB_DOMAINS=.*|WEB_DOMAINS='$NDOM'|" "$UC"
    sed -i "/^WEB_DOMAINS=/a WEB_SUBDOMAINS='$NSUB'" "$UC"
    # DNS y correo no deben limitar: solo mandan dominios y subdominios
    for CLAVE in DNS_DOMAINS MAIL_DOMAINS; do
        grep -q "^$CLAVE=" "$UC" && sed -i "s|^$CLAVE=.*|$CLAVE='unlimited'|" "$UC"
    done
    grep -q "^U_WEB_SUBDOMAINS=" "$UC" || sed -i "/^U_WEB_DOMAINS=/a U_WEB_SUBDOMAINS='0'" "$UC"
    "$HESTIA/bin/v-update-user-counters" "$USU" 2>/dev/null || true
    ok "Usuario '$USU': WEB_DOMAINS='$NDOM'  WEB_SUBDOMAINS='$NSUB'"
    grep -E "^(WEB_DOMAINS|WEB_SUBDOMAINS|U_WEB_DOMAINS|U_WEB_SUBDOMAINS)=" "$UC" | sed 's/^/  /'
    echo ""
    warn "Esto es un ajuste individual: si mas adelante le cambias el PLAN"
    warn "desde el panel, estos valores se sobreescriben con los del plan."
    exit 0
fi

# ------------------------------------------------------------------- --plan
# Ajusta un paquete a "X dominios / Y subdominios" dejando coherentes TODOS
# los cupos implicados. Hace falta porque en HestiaCP cada subdominio es
# tambien una zona DNS y un dominio de correo: si DNS_DOMAINS o MAIL_DOMAINS
# se quedan cortos, el panel crea el subdominio a medias y sin dar error.
if [ "${1:-}" = "--plan" ]; then
    PLAN="${2:-}"; NDOM="${3:-}"; NSUB="${4:-}"
    PKG="$HESTIA/data/packages/${PLAN}.pkg"
    if [ -z "$PLAN" ] || [ -z "$NDOM" ] || [ -z "$NSUB" ]; then
        echo "Uso: bash $0 --plan NOMBRE DOMINIOS SUBDOMINIOS"
        echo ""
        echo "  DOMINIOS     dominios de nivel superior, INCLUIDO el principal."
        echo "               Para 'principal + 2 adicionales' pon 3."
        echo "  SUBDOMINIOS  subdominios de sus propios dominios, o 'unlimited'."
        echo ""
        echo "Ejemplos:"
        echo "  bash $0 --plan basico 1 10         1 dominio, 10 subdominios"
        echo "  bash $0 --plan pro 3 unlimited     principal + 2 adicionales"
        echo ""
        echo "Paquetes disponibles:"
        ls -1 "$HESTIA/data/packages/"*.pkg 2>/dev/null \
            | sed 's|.*/||; s|\.pkg$||; s|^|  |'
        exit 1
    fi
    [ -f "$PKG" ] || { bad "No existe el paquete '$PLAN' ($PKG)"; exit 1; }
    case "$NDOM" in ''|*[!0-9]*) bad "DOMINIOS debe ser un numero"; exit 1 ;; esac
    [ "$NDOM" -lt 1 ] && { bad "DOMINIOS debe ser 1 o mas: el dominio principal tambien cuenta"; exit 1; }
    case "$NSUB" in
        unlimited|0|[1-9]*) ;;
        *) bad "SUBDOMINIOS debe ser un numero o 'unlimited'"; exit 1 ;;
    esac
    case "$NSUB" in
        unlimited) ;;
        *[!0-9]*) bad "SUBDOMINIOS debe ser un numero o 'unlimited'"; exit 1 ;;
    esac

    if ! grep -q "count_web_domains_split" "$HESTIA/func/main.sh" 2>/dev/null; then
        bad "El parche no esta aplicado todavia. Ejecuta primero: bash $0"
        exit 1
    fi

    cp -a "$PKG" "$PKG.bak-$(date +%Y%m%d-%H%M%S)"
    sed -i "/^WEB_SUBDOMAINS=/d" "$PKG"
    sed -i "s|^WEB_DOMAINS=.*|WEB_DOMAINS='$NDOM'|" "$PKG"
    sed -i "/^WEB_DOMAINS=/a WEB_SUBDOMAINS='$NSUB'" "$PKG"
    ok "WEB_DOMAINS='$NDOM'  WEB_SUBDOMAINS='$NSUB'"

    # DNS y correo: cada subdominio consume tambien uno de esos cupos
    # DNS y correo a 'unlimited': los unicos cupos que deben limitar son
    # dominios y subdominios. Si se dejan con numero, bloquean la creacion del
    # subdominio aunque queden subdominios libres, y encima sin dar error.
    for CLAVE in DNS_DOMAINS MAIL_DOMAINS; do
        ACTUAL=$(grep -m1 "^$CLAVE=" "$PKG" | cut -f2 -d\')
        if [ "$ACTUAL" = "unlimited" ]; then
            ok "$CLAVE ya era unlimited"
        elif [ -z "$ACTUAL" ]; then
            warn "$CLAVE no estaba en el paquete, se deja como esta"
        else
            sed -i "s|^$CLAVE=.*|$CLAVE='unlimited'|" "$PKG"
            ok "$CLAVE: '$ACTUAL' -> 'unlimited' (no debe limitar nada)"
        fi
    done

    echo ""
    echo "--- Paquete '$PLAN' ---"
    grep -E "^(WEB_DOMAINS|WEB_SUBDOMAINS|WEB_ALIASES|DNS_DOMAINS|MAIL_DOMAINS)=" "$PKG" | sed 's/^/  /'
    echo ""
    echo "Significa: $((NDOM - 1)) dominios adicionales (mas el principal)"
    echo "           $NSUB subdominios de sus propios dominios"
    echo ""
    echo "--- Propagando a los usuarios de este plan ---"
    if "$HESTIA/bin/v-update-user-package" "$PLAN" 2>&1 | sed 's/^/  /'; then
        ok "Plan propagado"
    else
        warn "v-update-user-package devolvio error: revisa si algun usuario ya"
        warn "supera los nuevos limites (a esos hay que subirles el plan primero)"
    fi
    exit 0
fi

# ---------------------------------------------------------- comprobaciones
echo "============================================================"
echo " Parche: limite de subdominios separado"
echo " Instalacion: $HESTIA"
echo "============================================================"
echo ""
echo "--- Comprobaciones previas ---"

[ -d "$HESTIA/bin" ] || { bad "No parece una instalacion de HestiaCP/QemuCP en $HESTIA"; exit 1; }
command -v patch >/dev/null || { bad "Falta el comando 'patch'. Instalalo: apt install -y patch"; exit 1; }

FALTA=0
for F in $FICHEROS; do
    [ -f "$HESTIA/$F" ] || { bad "no existe $HESTIA/$F"; FALTA=1; }
done
[ "$FALTA" -ne 0 ] && { bad "Instalacion inesperada, no se aplica nada"; exit 1; }
ok "Los 13 ficheros a modificar estan presentes"

# Si ya esta aplicado se sale ANTES de hacer backup. De lo contrario el backup
# guardaria los ficheros ya parcheados y --revertir dejaria de servir.
YA_APLICADO="no"
if grep -q "count_web_domains_split" "$HESTIA/func/main.sh" 2>/dev/null; then
    ok "El parche ya estaba aplicado en esta instalacion"
    YA_APLICADO="si"
fi

# ------------------------------------------------------------------ backup
if [ "$YA_APLICADO" = "si" ]; then
    echo ""
    echo "--- No se reaplica (ya estaba) ---"
fi
if [ "$YA_APLICADO" = "no" ]; then
echo ""
echo "--- Backup ---"
for F in $FICHEROS; do
    mkdir -p "$BACKUP/$(dirname "$F")"
    cp -a "$HESTIA/$F" "$BACKUP/$F"
done
ok "Copia de seguridad en $BACKUP"

# ------------------------------------------------------------------ aplicar
echo ""
echo "--- Aplicando ---"
PATCHFILE=$(mktemp /tmp/qemucp-sub.XXXXXX.patch)
cat > "$PATCHFILE" <<'FIN_DEL_PARCHE'
diff --git a/bin/v-add-domain b/bin/v-add-domain
index be69cbe50..9e11ee13d 100755
--- a/bin/v-add-domain
+++ b/bin/v-add-domain
@@ -54,7 +54,10 @@ fi
 
 # Working on web domain
 if [ -n "$WEB_SYSTEM" ]; then
-	check1=$(is_package_full 'WEB_DOMAINS')
+	# QemuCP: un subdominio cuenta contra WEB_SUBDOMAINS, no contra WEB_DOMAINS.
+	# Sin esto, con el cupo de dominios lleno pero subdominios libres, este
+	# pre-chequeo se saltaria la creacion de la parte web sin dar ningun error.
+	check1=$(is_package_full "$(web_quota_key "$domain")")
 	if [ $? -eq 0 ]; then
 		$BIN/v-add-web-domain "$user" "$domain" "$ip" 'no'
 		check_result $? "can't add web domain"
diff --git a/bin/v-add-user b/bin/v-add-user
index a0cda7871..38ce6fe1d 100755
--- a/bin/v-add-user
+++ b/bin/v-add-user
@@ -248,6 +248,7 @@ U_DISK_MAIL='0'
 U_DISK_DB='0'
 U_BANDWIDTH='0'
 U_WEB_DOMAINS='0'
+U_WEB_SUBDOMAINS='0'
 U_WEB_SSL='0'
 U_WEB_ALIASES='0'
 U_DNS_DOMAINS='0'
diff --git a/bin/v-add-user-package b/bin/v-add-user-package
index 816dc3970..7a6542e9f 100755
--- a/bin/v-add-user-package
+++ b/bin/v-add-user-package
@@ -133,6 +133,7 @@ PROXY_TEMPLATE='$PROXY_TEMPLATE'
 BACKEND_TEMPLATE='$BACKEND_TEMPLATE'
 DNS_TEMPLATE='$DNS_TEMPLATE'
 WEB_DOMAINS='$WEB_DOMAINS'
+WEB_SUBDOMAINS='${WEB_SUBDOMAINS:-unlimited}'
 WEB_ALIASES='$WEB_ALIASES'
 DNS_DOMAINS='$DNS_DOMAINS'
 DNS_RECORDS='$DNS_RECORDS'
diff --git a/bin/v-add-web-domain b/bin/v-add-web-domain
index e50498658..50ef2632b 100755
--- a/bin/v-add-web-domain
+++ b/bin/v-add-web-domain
@@ -53,7 +53,11 @@ check_args '2' "$#" 'USER DOMAIN [IP] [RESTART] [ALIASES] [PROXY_EXTENSIONS]'
 is_format_valid 'user' 'domain' 'aliases' 'ip' 'proxy_ext' 'restart'
 is_object_valid 'user' 'USER' "$user"
 is_object_unsuspended 'user' 'USER' "$user"
-is_package_full 'WEB_DOMAINS'
+
+# QemuCP: en cPanel un subdominio de un dominio que ya aloja la cuenta no gasta
+# cupo de "addon domains", sino el suyo propio. web_quota_key decide contra que
+# limite cuenta este dominio (ver func/main.sh).
+is_package_full "$(web_quota_key "$domain")"
 
 if [ "$aliases" != "none" ]; then
 	ALIAS="$aliases"
diff --git a/bin/v-change-user-package b/bin/v-change-user-package
index b05acc641..3194328af 100755
--- a/bin/v-change-user-package
+++ b/bin/v-change-user-package
@@ -33,15 +33,34 @@ is_package_available() {
 	DNS_DOMAINS='0'
 	DISK_QUOTA='0'
 	BANDWIDTH='0'
+	WEB_SUBDOMAINS=''
 
 	source_conf "$HESTIA/data/packages/$package.pkg"
 
+	# QemuCP: si el paquete destino separa subdominios, el uso actual hay que
+	# compararlo tambien separado. Los contadores U_WEB_* del usuario pueden
+	# venir todavia del esquema antiguo (U_WEB_DOMAINS = total), asi que se
+	# recalculan aqui sobre web.conf en lugar de confiar en ellos.
+	if [ -n "$WEB_SUBDOMAINS" ]; then
+		_split=$(count_web_domains_split "$USER_DATA/web.conf")
+		_used_top=$(echo "$_split" | cut -f 1 -d \ )
+		_used_sub=$(echo "$_split" | cut -f 2 -d \ )
+	else
+		_used_top="$U_WEB_DOMAINS"
+		_used_sub=0
+	fi
+
 	# Checking usage agains package limits
 	if [ "$WEB_DOMAINS" != 'unlimited' ]; then
-		if [ "$WEB_DOMAINS" -lt "$U_WEB_DOMAINS" ]; then
+		if [ "$WEB_DOMAINS" -lt "$_used_top" ]; then
 			check_result "$E_LIMIT" "Package doesn't cover WEB_DOMAIN usage"
 		fi
 	fi
+	if [ -n "$WEB_SUBDOMAINS" ] && [ "$WEB_SUBDOMAINS" != 'unlimited' ]; then
+		if [ "$WEB_SUBDOMAINS" -lt "$_used_sub" ]; then
+			check_result "$E_LIMIT" "Package doesn't cover WEB_SUBDOMAIN usage"
+		fi
+	fi
 	if [ "$DNS_DOMAINS" != 'unlimited' ]; then
 		if [ "$DNS_DOMAINS" -lt "$U_DNS_DOMAINS" ]; then
 			check_result "$E_LIMIT" "Package doesn't cover DNS_DOMAIN usage"
@@ -87,6 +106,7 @@ BACKEND_TEMPLATE='$BACKEND_TEMPLATE'
 PROXY_TEMPLATE='$PROXY_TEMPLATE'
 DNS_TEMPLATE='$DNS_TEMPLATE'
 WEB_DOMAINS='$WEB_DOMAINS'
+WEB_SUBDOMAINS='$WEB_SUBDOMAINS'
 WEB_ALIASES='$WEB_ALIASES'
 DNS_DOMAINS='$DNS_DOMAINS'
 DNS_RECORDS='$DNS_RECORDS'
@@ -130,6 +150,7 @@ U_DISK_MAIL='$U_DISK_MAIL'
 U_DISK_DB='$U_DISK_DB'
 U_BANDWIDTH='$U_BANDWIDTH'
 U_WEB_DOMAINS='$U_WEB_DOMAINS'
+U_WEB_SUBDOMAINS='$U_WEB_SUBDOMAINS'
 U_WEB_SSL='$U_WEB_SSL'
 U_WEB_ALIASES='$U_WEB_ALIASES'
 U_DNS_DOMAINS='$U_DNS_DOMAINS'
diff --git a/bin/v-list-user b/bin/v-list-user
index 66566a4de..b851364f8 100755
--- a/bin/v-list-user
+++ b/bin/v-list-user
@@ -32,6 +32,7 @@ json_list() {
         "PROXY_TEMPLATE": "'$PROXY_TEMPLATE'",
         "DNS_TEMPLATE": "'$DNS_TEMPLATE'",
         "WEB_DOMAINS": "'$WEB_DOMAINS'",
+        "WEB_SUBDOMAINS": "'$WEB_SUBDOMAINS'",
         "WEB_ALIASES": "'$WEB_ALIASES'",
         "DNS_DOMAINS": "'$DNS_DOMAINS'",
         "DNS_RECORDS": "'$DNS_RECORDS'",
@@ -68,6 +69,7 @@ json_list() {
         "U_DISK_DB": "'$U_DISK_DB'",
         "U_BANDWIDTH": "'$U_BANDWIDTH'",
         "U_WEB_DOMAINS": "'$U_WEB_DOMAINS'",
+        "U_WEB_SUBDOMAINS": "'$U_WEB_SUBDOMAINS'",
         "U_WEB_SSL": "'$U_WEB_SSL'",
         "U_WEB_ALIASES": "'$U_WEB_ALIASES'",
         "U_DNS_DOMAINS": "'$U_DNS_DOMAINS'",
@@ -104,6 +106,7 @@ shell_list() {
 	echo "PACKAGE:       $PACKAGE"
 	echo "SHELL:         $SHELL"
 	echo "WEB DOMAINS:   $U_WEB_DOMAINS/$WEB_DOMAINS"
+	echo "WEB SUBDOMAINS: ${U_WEB_SUBDOMAINS:-0}/${WEB_SUBDOMAINS:-n/a}"
 	echo "WEB ALIASES:   $U_WEB_ALIASES/$WEB_ALIASES"
 	echo "DNS DOMAINS:   $U_DNS_DOMAINS/$DNS_DOMAINS"
 	echo "DNS RECORDS:   $U_DNS_RECORDS/$DNS_RECORDS"
diff --git a/bin/v-list-user-package b/bin/v-list-user-package
index f0b0e3cb7..ef64d14e3 100755
--- a/bin/v-list-user-package
+++ b/bin/v-list-user-package
@@ -29,6 +29,7 @@ json_list() {
         "PROXY_TEMPLATE": "'$PROXY_TEMPLATE'",
         "DNS_TEMPLATE": "'$DNS_TEMPLATE'",
         "WEB_DOMAINS": "'$WEB_DOMAINS'",
+        "WEB_SUBDOMAINS": "'$WEB_SUBDOMAINS'",
         "WEB_ALIASES": "'$WEB_ALIASES'",
         "DNS_DOMAINS": "'$DNS_DOMAINS'",
         "DNS_RECORDS": "'$DNS_RECORDS'",
@@ -61,6 +62,7 @@ shell_list() {
 	echo "PROXY TEMPLATE:   $PROXY_TEMPLATE"
 	echo "DNS TEMPLATE:     $DNS_TEMPLATE"
 	echo "WEB DOMAINS:      $WEB_DOMAINS"
+	echo "WEB SUBDOMAINS:   $WEB_SUBDOMAINS"
 	echo "WEB ALIASES:      $WEB_ALIASES"
 	echo "DNS DOMAINS:      $DNS_DOMAINS"
 	echo "DNS RECORDS:      $DNS_RECORDS"
diff --git a/bin/v-list-user-packages b/bin/v-list-user-packages
index 1b90a04e7..06d9173b1 100755
--- a/bin/v-list-user-packages
+++ b/bin/v-list-user-packages
@@ -27,12 +27,16 @@ json_list() {
 	echo "{"
 	for package in $packages; do
 		PACKAGE=${package/.pkg/}
+		# QemuCP: limpiar antes de cada source_conf. Es un bucle, y un paquete
+		# sin WEB_SUBDOMAINS heredaria el valor del paquete anterior.
+		WEB_SUBDOMAINS=''
 		source_conf "$HESTIA/data/packages/$PACKAGE.pkg"
 		echo -n '    "'$PACKAGE'": {
         "WEB_TEMPLATE": "'$WEB_TEMPLATE'",
         "PROXY_TEMPLATE": "'$PROXY_TEMPLATE'",
         "DNS_TEMPLATE": "'$DNS_TEMPLATE'",
         "WEB_DOMAINS": "'$WEB_DOMAINS'",
+        "WEB_SUBDOMAINS": "'$WEB_SUBDOMAINS'",
         "WEB_ALIASES": "'$WEB_ALIASES'",
         "DNS_DOMAINS": "'$DNS_DOMAINS'",
         "DNS_RECORDS": "'$DNS_RECORDS'",
diff --git a/bin/v-update-user-counters b/bin/v-update-user-counters
index 586f8aa1c..a5d1ed452 100755
--- a/bin/v-update-user-counters
+++ b/bin/v-update-user-counters
@@ -67,6 +67,7 @@ for user in $user_list; do
 	BANDWIDTH=0
 	U_BANDWIDTH=0
 	U_WEB_DOMAINS=0
+	U_WEB_SUBDOMAINS=0
 	U_WEB_SSL=0
 	U_WEB_ALIASES=0
 	U_DNS_DOMAINS=0
@@ -106,6 +107,7 @@ for user in $user_list; do
 
 	# Checking web system
 	U_WEB_DOMAINS=0
+	U_WEB_SUBDOMAINS=0
 	if [ -f $USER_DATA/web.conf ]; then
 		for domain_str in $(cat $USER_DATA/web.conf); do
 			parse_object_kv_list "$domain_str"
@@ -125,6 +127,13 @@ for user in $user_list; do
 			BANDWIDTH=$((BANDWIDTH + U_BANDWIDTH))
 		done
 		DISK=$((DISK + U_DISK_WEB))
+		# QemuCP: si el paquete separa subdominios (WEB_SUBDOMAINS), los
+		# contadores deben separarse igual que los limites, para que el panel
+		# muestre "usados/limite" coherente en ambas filas.
+		if has_split_subdomain_limit; then
+			U_WEB_DOMAINS=$(count_web_domains_split "$USER_DATA/web.conf" | cut -f 1 -d \ )
+			U_WEB_SUBDOMAINS=$(count_web_domains_split "$USER_DATA/web.conf" | cut -f 2 -d \ )
+		fi
 	fi
 
 	# Checking dns system
@@ -210,6 +219,7 @@ for user in $user_list; do
 	update_user_value "$user" '$U_DISK_DB' "$U_DISK_DB"
 	update_user_value "$user" '$U_BANDWIDTH' "$U_BANDWIDTH"
 	update_user_value "$user" '$U_WEB_DOMAINS' "$U_WEB_DOMAINS"
+	update_user_value "$user" '$U_WEB_SUBDOMAINS' "$U_WEB_SUBDOMAINS"
 	update_user_value "$user" '$U_WEB_SSL' "$U_WEB_SSL"
 	update_user_value "$user" '$U_WEB_ALIASES' "$U_WEB_ALIASES"
 	update_user_value "$user" '$U_DNS_DOMAINS' "$U_DNS_DOMAINS"
diff --git a/func/main.sh b/func/main.sh
index 8b59d2e26..a78e9307b 100644
--- a/func/main.sh
+++ b/func/main.sh
@@ -267,10 +267,81 @@ is_system_enabled() {
 	fi
 }
 
+# QemuCP: cuenta los dominios web del usuario separando dominios de nivel
+# superior (lo que cPanel llama "addon domains") de los subdominios de otro
+# dominio del MISMO usuario (lo que cPanel llama "subdomains").
+# Imprime "<dominios> <subdominios>".
+count_web_domains_split() {
+	local _conf="$1"
+	local _doms _d _p _top=0 _sub=0 _is_sub
+	[ -f "$_conf" ] || { echo "0 0"; return; }
+	_doms=$(grep -o "DOMAIN='[^']*'" "$_conf" | cut -f 2 -d \')
+	for _d in $_doms; do
+		_is_sub=0
+		for _p in $_doms; do
+			[ "$_d" = "$_p" ] && continue
+			case "$_d" in
+				*".$_p")
+					_is_sub=1
+					break
+					;;
+			esac
+		done
+		if [ "$_is_sub" -eq 1 ]; then
+			_sub=$((_sub + 1))
+		else
+			_top=$((_top + 1))
+		fi
+	done
+	echo "$_top $_sub"
+}
+
+# QemuCP: cierto si el paquete del usuario define WEB_SUBDOMAINS, es decir si
+# los subdominios tienen su propio limite como en cPanel. Si la clave no existe
+# (paquetes anteriores a este parche) se conserva el comportamiento historico:
+# WEB_DOMAINS cuenta dominios Y subdominios juntos.
+has_split_subdomain_limit() {
+	local _v
+	_v=$(grep -m 1 "^WEB_SUBDOMAINS=" "$USER_DATA/user.conf" 2> /dev/null | cut -f 2 -d \')
+	# Clave ausente o vacia = esquema antiguo (todo cuenta en WEB_DOMAINS).
+	[ -n "$_v" ]
+}
+
+# QemuCP: nombre del limite contra el que debe contar el dominio indicado.
+# Devuelve WEB_SUBDOMAINS si es X.DOMINIO de un dominio que ya aloja este
+# usuario y su paquete separa subdominios; WEB_DOMAINS en el resto de casos.
+# Centralizado aqui porque lo necesitan v-add-web-domain y v-add-domain, y si
+# cada uno lo decidiera por su cuenta se descuadrarian: v-add-domain
+# pre-comprueba el limite y se salta la creacion web sin avisar.
+web_quota_key() {
+	local _dom="$1" _p
+	if ! has_split_subdomain_limit; then
+		echo 'WEB_DOMAINS'
+		return
+	fi
+	for _p in $(grep -o "DOMAIN='[^']*'" "$USER_DATA/web.conf" 2> /dev/null | cut -f 2 -d \'); do
+		[ "$_dom" = "$_p" ] && continue
+		case "$_dom" in
+			*".$_p")
+				echo 'WEB_SUBDOMAINS'
+				return
+				;;
+		esac
+	done
+	echo 'WEB_DOMAINS'
+}
+
 # User package check
 is_package_full() {
 	case "$1" in
-		WEB_DOMAINS) used=$(wc -l $USER_DATA/web.conf) ;;
+		WEB_DOMAINS)
+			if has_split_subdomain_limit; then
+				used=$(count_web_domains_split "$USER_DATA/web.conf" | cut -f 1 -d \ )
+			else
+				used=$(wc -l $USER_DATA/web.conf)
+			fi
+			;;
+		WEB_SUBDOMAINS) used=$(count_web_domains_split "$USER_DATA/web.conf" | cut -f 2 -d \ ) ;;
 		WEB_ALIASES) used=$(echo $aliases | tr ',' '\n' | wc -l) ;;
 		DNS_DOMAINS) used=$(wc -l $USER_DATA/dns.conf) ;;
 		DNS_RECORDS) used=$(wc -l $USER_DATA/dns/$domain.conf) ;;
@@ -281,6 +352,10 @@ is_package_full() {
 	esac
 	used=$(echo "$used" | cut -f 1 -d \ )
 	limit=$(grep "^$1=" $USER_DATA/user.conf | cut -f 2 -d \')
+	# QemuCP: una clave ausente en user.conf equivale a 'unlimited'. Sin esto,
+	# un limite vacio se evalua como 0 en la comparacion aritmetica y bloquea
+	# la creacion en los usuarios cuyo paquete aun no tiene la clave nueva.
+	[ -z "$limit" ] && limit='unlimited'
 	if [ "$1" = WEB_ALIASES ]; then
 		# Used is always calculated with the new alias added
 		if [ "$limit" != 'unlimited' ] && [[ "$used" -gt "$limit" ]]; then
diff --git a/web/add/package/index.php b/web/add/package/index.php
index 32d5e2507..bb2b10b09 100644
--- a/web/add/package/index.php
+++ b/web/add/package/index.php
@@ -50,6 +50,9 @@ if (!empty($_POST["ok"])) {
 	if (!isset($_POST["v_web_domains"])) {
 		$errors[] = _("Web Domains");
 	}
+	if (!isset($_POST["v_web_subdomains"])) {
+		$errors[] = _("Web Subdomains");
+	}
 	if (!isset($_POST["v_web_aliases"])) {
 		$errors[] = _("Web Aliases");
 	}
@@ -129,6 +132,7 @@ if (!empty($_POST["ok"])) {
 		$v_dns_template = quoteshellarg($_POST["v_dns_template"]);
 		$v_shell = quoteshellarg($_POST["v_shell"]);
 		$v_web_domains = quoteshellarg($_POST["v_web_domains"]);
+		$v_web_subdomains = quoteshellarg($_POST["v_web_subdomains"]);
 		$v_web_aliases = quoteshellarg($_POST["v_web_aliases"]);
 		$v_dns_domains = quoteshellarg($_POST["v_dns_domains"]);
 		$v_dns_records = quoteshellarg($_POST["v_dns_records"]);
@@ -196,6 +200,9 @@ if (!empty($_POST["ok"])) {
 			}
 			$pkg .= "DNS_TEMPLATE=" . $v_dns_template . "\n";
 			$pkg .= "WEB_DOMAINS=" . $v_web_domains . "\n";
+			if (trim($_POST["v_web_subdomains"]) !== "") {
+				$pkg .= "WEB_SUBDOMAINS=" . $v_web_subdomains . "\n";
+			}
 			$pkg .= "WEB_ALIASES=" . $v_web_aliases . "\n";
 			$pkg .= "DNS_DOMAINS=" . $v_dns_domains . "\n";
 			$pkg .= "DNS_RECORDS=" . $v_dns_records . "\n";
@@ -297,6 +304,9 @@ if (empty($v_shell)) {
 if (empty($v_web_domains)) {
 	$v_web_domains = "'1'";
 }
+if (empty($v_web_subdomains)) {
+	$v_web_subdomains = "'unlimited'";
+}
 if (empty($v_web_aliases)) {
 	$v_web_aliases = "'5'";
 }
diff --git a/web/edit/package/index.php b/web/edit/package/index.php
index 6085f5e9d..e02cb361a 100644
--- a/web/edit/package/index.php
+++ b/web/edit/package/index.php
@@ -40,6 +40,10 @@ $v_backend_template = $data[$v_package]["BACKEND_TEMPLATE"];
 $v_proxy_template = $data[$v_package]["PROXY_TEMPLATE"];
 $v_dns_template = $data[$v_package]["DNS_TEMPLATE"];
 $v_web_domains = $data[$v_package]["WEB_DOMAINS"];
+// Vacio = paquete heredado: los subdominios siguen contando como dominios.
+// No se rellena con "unlimited" para que editar otro campo del paquete no
+// cambie el esquema sin que el administrador lo pida expresamente.
+$v_web_subdomains = $data[$v_package]["WEB_SUBDOMAINS"] ?? "";
 $v_web_aliases = $data[$v_package]["WEB_ALIASES"];
 $v_dns_domains = $data[$v_package]["DNS_DOMAINS"];
 $v_dns_records = $data[$v_package]["DNS_RECORDS"];
@@ -163,6 +167,9 @@ if (!empty($_POST["save"])) {
 	if (!isset($_POST["v_web_domains"])) {
 		$errors[] = _("Web Domains");
 	}
+	if (!isset($_POST["v_web_subdomains"])) {
+		$errors[] = _("Web Subdomains");
+	}
 	if (!isset($_POST["v_web_aliases"])) {
 		$errors[] = _("Web Aliases");
 	}
@@ -253,6 +260,7 @@ if (!empty($_POST["save"])) {
 		$v_shell = "nologin";
 	}
 	$v_web_domains = quoteshellarg($_POST["v_web_domains"]);
+	$v_web_subdomains = quoteshellarg($_POST["v_web_subdomains"]);
 	$v_web_aliases = quoteshellarg($_POST["v_web_aliases"]);
 	$v_dns_domains = quoteshellarg($_POST["v_dns_domains"]);
 	$v_dns_records = quoteshellarg($_POST["v_dns_records"]);
@@ -312,6 +320,9 @@ if (!empty($_POST["save"])) {
 	$pkg .= "PROXY_TEMPLATE=" . $v_proxy_template . "\n";
 	$pkg .= "DNS_TEMPLATE=" . $v_dns_template . "\n";
 	$pkg .= "WEB_DOMAINS=" . $v_web_domains . "\n";
+	if (trim($_POST["v_web_subdomains"]) !== "") {
+		$pkg .= "WEB_SUBDOMAINS=" . $v_web_subdomains . "\n";
+	}
 	$pkg .= "WEB_ALIASES=" . $v_web_aliases . "\n";
 	$pkg .= "DNS_DOMAINS=" . $v_dns_domains . "\n";
 	$pkg .= "DNS_RECORDS=" . $v_dns_records . "\n";
diff --git a/web/templates/pages/add_package.php b/web/templates/pages/add_package.php
index 111df452d..671315575 100644
--- a/web/templates/pages/add_package.php
+++ b/web/templates/pages/add_package.php
@@ -81,6 +81,17 @@
 							</button>
 						</div>
 					</div>
+					<div class="u-mb10">
+						<label for="v_web_subdomains" class="form-label">
+							<?= tohtml( _("Web Subdomains")) ?> <span class="optional">(<?= tohtml( _("subdomains of own domains; empty = count as domains")) ?>)</span>
+						</label>
+						<div class="u-pos-relative">
+							<input type="text" class="form-control" name="v_web_subdomains" id="v_web_subdomains" value="<?= tohtml(trim($v_web_subdomains, "'")) ?>">
+							<button type="button" class="unlimited-toggle js-unlimited-toggle" title="<?= tohtml( _("Unlimited")) ?>">
+								<i class="fas fa-infinity"></i>
+							</button>
+						</div>
+					</div>
 					<div class="u-mb10">
 						<label for="v_web_aliases" class="form-label">
 							<?= tohtml( _("Web Aliases")) ?> <span class="optional">(<?= tohtml( _("per domain")) ?>)</span>
diff --git a/web/templates/pages/edit_package.php b/web/templates/pages/edit_package.php
index 0272fd99b..cbcb57ab5 100644
--- a/web/templates/pages/edit_package.php
+++ b/web/templates/pages/edit_package.php
@@ -83,6 +83,17 @@
 							</button>
 						</div>
 					</div>
+					<div class="u-mb10">
+						<label for="v_web_subdomains" class="form-label">
+							<?= tohtml( _("Web Subdomains")) ?> <span class="optional">(<?= tohtml( _("subdomains of own domains; empty = count as domains")) ?>)</span>
+						</label>
+						<div class="u-pos-relative">
+							<input type="text" class="form-control" name="v_web_subdomains" id="v_web_subdomains" value="<?= tohtml(trim($v_web_subdomains, "'")) ?>">
+							<button type="button" class="unlimited-toggle js-unlimited-toggle" title="<?= tohtml( _("Unlimited")) ?>">
+								<i class="fas fa-infinity"></i>
+							</button>
+						</div>
+					</div>
 					<div class="u-mb10">
 						<label for="v_web_aliases" class="form-label">
 							<?= tohtml( _("Web Aliases")) ?> <span class="optional">(<?= tohtml( _("per domain")) ?>)</span>
FIN_DEL_PARCHE

cd "$HESTIA" || exit 1
SALIDA=$(patch -p1 --forward -F3 --no-backup-if-mismatch -r - < "$PATCHFILE" 2>&1)
RES=$?
echo "$SALIDA" | sed 's/^/  /'
rm -f "$PATCHFILE"
# -r - descarta los .rej; por si alguna version de patch los deja igualmente:
find "$HESTIA/bin" "$HESTIA/func" "$HESTIA/web" \
    \( -name "*.rej" -o -name "*.orig" \) -delete 2>/dev/null

# patch devuelve 1 cuando algun trozo ya estaba aplicado (--forward): eso no
# es un fallo. Solo es fallo si quedaron .rej o si algo no se pudo aplicar.
if echo "$SALIDA" | grep -q "FAILED\|malformed\|can't find file"; then
    bad "El parche no se aplico limpiamente. Restaurando el backup..."
    # Aviso visible en el panel: si esto ocurre tras un apt upgrade, el limite
    # de subdominios deja de aplicarse y hay que enterarse, no descubrirlo
    # cuando un cliente cree dominios que no deberia poder crear.
    "$HESTIA/bin/v-add-user-notification" admin \
        "QemuCP: limite de subdominios DESACTIVADO" \
        "El parche no se pudo reaplicar sobre esta version de HestiaCP. Los paquetes con WEB_SUBDOMAINS han dejado de limitar subdominios. Revisa /var/log/qemucp-subdominios.log" \
        2>/dev/null || true
    for F in $FICHEROS; do cp -a "$BACKUP/$F" "$HESTIA/$F"; done
    find "$HESTIA" -name "*.rej" -newer "$BACKUP" -delete 2>/dev/null
    bad "Sin cambios. Revisa la version de QemuCP: este parche es para 1.10.5."
    exit 1
fi
[ "$RES" -ne 0 ] && warn "patch devolvio $RES (normal si ya estaba aplicado)"

fi   # fin de: if [ "$YA_APLICADO" = "no" ]

# -------------------------------------------------------------- verificacion
echo ""
echo "--- Verificando ---"
ERR=0
for F in func/main.sh bin/v-add-web-domain bin/v-add-domain bin/v-add-user bin/v-add-user-package bin/v-change-user-package bin/v-update-user-counters bin/v-list-user bin/v-list-user-package bin/v-list-user-packages; do
    if bash -n "$HESTIA/$F" 2>/dev/null; then ok "sintaxis bash $F"; else bad "sintaxis bash ROTA en $F"; ERR=1; fi
done
PHPBIN=$(command -v php || ls /usr/bin/php* 2>/dev/null | head -1)
if [ -n "$PHPBIN" ]; then
    for F in web/add/package/index.php web/edit/package/index.php \
             web/templates/pages/add_package.php web/templates/pages/edit_package.php; do
        if $PHPBIN -l "$HESTIA/$F" >/dev/null 2>&1; then ok "sintaxis php $F"; else bad "sintaxis php ROTA en $F"; ERR=1; fi
    done
else
    warn "No se encontro el binario php, no se comprueba la sintaxis PHP"
fi

for MARCA in count_web_domains_split has_split_subdomain_limit; do
    grep -q "$MARCA" "$HESTIA/func/main.sh" && ok "funcion $MARCA presente" \
        || { bad "falta $MARCA en func/main.sh"; ERR=1; }
done
for B in v-add-web-domain v-add-domain; do
    grep -q "web_quota_key" "$HESTIA/bin/$B" && ok "chequeo de cupo en $B" \
        || { bad "falta el chequeo de cupo en $B"; ERR=1; }
done
grep -q "web_quota_key" "$HESTIA/func/main.sh" && ok "funcion web_quota_key presente" \
    || { bad "falta web_quota_key en func/main.sh"; ERR=1; }
grep -q "v_web_subdomains" "$HESTIA/web/templates/pages/edit_package.php" && ok "campo en el formulario de paquetes" \
    || { bad "falta el campo en el formulario"; ERR=1; }

if [ "$ERR" -ne 0 ]; then
    echo ""
    bad "Verificacion con errores. Restaurando el backup..."
    for F in $FICHEROS; do cp -a "$BACKUP/$F" "$HESTIA/$F"; done
    systemctl restart hestia 2>/dev/null
    bad "Revertido. Nada quedo modificado."
    exit 1
fi

# -------------------------------------------- prueba real sin tocar nada
echo ""
echo "--- Conteo actual por usuario (solo informativo) ---"
# Se carga SOLO la funcion de conteo. No se hace 'source func/main.sh' porque
# arrastra hestia.conf y los codigos de error del panel y aborta el script.
FN=$(mktemp /tmp/qemucp-fn.XXXXXX.sh)
sed -n '/^count_web_domains_split()/,/^}/p' "$HESTIA/func/main.sh" > "$FN"
# shellcheck disable=SC1090
. "$FN"
rm -f "$FN"
printf "  %-16s %10s %13s  %s\n" USUARIO DOMINIOS SUBDOMINIOS ESQUEMA
for UD in "$HESTIA"/data/users/*/; do
    [ -d "$UD" ] || continue
    U=$(basename "$UD")
    [ -f "$UD/web.conf" ] || continue
    S=$(count_web_domains_split "$UD/web.conf")
    LIM=$(grep -m1 "^WEB_SUBDOMAINS=" "$UD/user.conf" 2>/dev/null | cut -f2 -d\')
    if [ -n "$LIM" ]; then ESQ="separado (limite $LIM)"; else ESQ="antiguo (todo en WEB_DOMAINS)"; fi
    printf "  %-16s %10s %13s  %s\n" "$U" "$(echo "$S" | cut -f1 -d' ')" "$(echo "$S" | cut -f2 -d' ')" "$ESQ"
done

systemctl restart hestia 2>/dev/null && ok "Panel reiniciado"

# ------------------------------------------------- persistencia tras apt upgrade
# El paquete hestia sobrescribe bin/ y func/ en cada actualizacion, asi que sin
# esto el limite de subdominios desaparece en silencio al primer apt upgrade.
echo ""
echo "--- Persistencia tras actualizar HestiaCP ---"
DESTINO="$HESTIA/data/qemucp"
mkdir -p "$DESTINO"
PROPIO=$(readlink -f "$0")
if [ "$PROPIO" != "$DESTINO/parche-subdominios.sh" ]; then
    cp -a "$PROPIO" "$DESTINO/parche-subdominios.sh"
    chmod +x "$DESTINO/parche-subdominios.sh"
    ok "Copia instalada en $DESTINO/parche-subdominios.sh"
fi

# El unico hook que HestiaCP ejecuta es /etc/hestiacp/hooks/post_install.sh,
# invocado al final del postinst del paquete hestia. La ruta
# data/hooks/post_update.sh que se usaba antes NO se ejecuta nunca.
HOOK="/etc/hestiacp/hooks/post_install.sh"
mkdir -p /etc/hestiacp/hooks
if [ -e "$HOOK" ] && grep -q "parche-subdominios.sh" "$HOOK" 2>/dev/null; then
    ok "El hook post_install ya lo reaplica"
elif [ -e "$HOOK" ] && grep -q "QemuCP-BLOQUE-INICIO" "$HOOK" 2>/dev/null; then
    warn "El hook de QemuCP existe pero no invoca este parche."
    warn "Reinstalalo para que lo incluya:  bash /root/instalar-hook.sh"
else
    warn "No hay hook de post-actualizacion instalado."
    warn "Sin el, este parche se PIERDE en el proximo 'apt upgrade' de hestia."
    warn "Instalalo con:  bash /root/instalar-hook.sh"
fi

cat <<'SIGUIENTE'

============================================================
 Parche aplicado
============================================================

Ahora mismo NADA ha cambiado para tus clientes: todos los paquetes
siguen en el esquema antiguo hasta que les pongas un valor.

Para pasar un plan al esquema cPanel, desde el panel:
  Paquetes -> editar el plan -> aparecen dos campos:
      Web Domains      -> dominios adicionales (0 = ninguno)
      Web Subdomains   -> subdominios de sus propios dominios
  Guardar. El panel propaga el plan a los usuarios que lo tengan.

Por SSH, equivalente (plan "basico": 0 adicionales, 10 subdominios):
  P=/usr/local/hestia/data/packages/basico.pkg
  sed -i "/^WEB_SUBDOMAINS=/d" $P
  sed -i "/^WEB_DOMAINS=/a WEB_SUBDOMAINS='10'" $P
  sed -i "s/^WEB_DOMAINS=.*/WEB_DOMAINS='1'/" $P
  v-update-user-package basico

  Ojo: WEB_DOMAINS='1' es el dominio PRINCIPAL. Para "sin dominios
  adicionales" el valor es 1, no 0, porque el principal tambien cuenta
  como dominio de nivel superior.

Comprobar que funciona, con un usuario de ese plan:
  v-add-web-domain USUARIO sub1.sudominio.com     <- debe dejar
  v-add-web-domain USUARIO otrodominio.es         <- debe dar
                   "WEB_DOMAINS limit is reached"

Deshacer todo:
  bash parche-subdominios.sh --revertir

SIGUIENTE
exit 0
QEMUCP_EMBED_SUB
cat > "$AUX_DIR/arreglar-crons.sh" << 'QEMUCP_EMBED_CRON'
#!/bin/bash
# ============================================================================
#  QemuCP - Cola de reinicios y crons del sistema
#
#  Problema que resuelve:
#    HestiaCP NO reinicia los servicios al crear un dominio: los apunta en
#    /usr/local/hestia/data/queue/restart.pipe y los procesa un cron del
#    usuario hestiaweb:
#        */2 * * * * sudo /usr/local/hestia/bin/v-update-sys-queue restart
#    Si ese crontab falta, esta incompleto o tiene mal el propietario o los
#    permisos, cron lo ignora EN SILENCIO. Resultado: creas una web, la zona
#    queda escrita en named.conf pero BIND no la ha leido, y el dominio no
#    resuelve aunque este apuntando. Al guardar la zona desde el panel se
#    fuerza un reinicio inmediato y entonces "empieza a funcionar sin tocar
#    nada".
#
#  Uso:
#    bash arreglar-crons.sh              comprueba y corrige
#    bash arreglar-crons.sh --verificar  solo comprueba, no cambia nada
# ============================================================================

set -u
HESTIA="${HESTIA:-/usr/local/hestia}"
CRONTAB="/var/spool/cron/crontabs/hestiaweb"
SOLO_VER="no"
[ "${1:-}" = "--verificar" ] && SOLO_VER="si"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}OK${NC}     $1"; }
bad()  { echo -e "  ${RED}FALLO${NC}  $1"; }
warn() { echo -e "  ${YELLOW}AVISO${NC}  $1"; }

# Las 11 tareas que instala HestiaCP, en el mismo orden y con el mismo horario.
# Se identifican por el COMANDO, no por la linea completa, para no duplicar una
# tarea cuyo horario se haya cambiado a proposito.
TAREAS=(
    "*/2 * * * *|v-update-sys-queue restart"
    "10 00 * * *|v-update-sys-queue daily"
    "15 02 * * *|v-update-sys-queue disk"
    "10 00 * * *|v-update-sys-queue traffic"
    "30 03 * * *|v-update-sys-queue webstats"
    "*/5 * * * *|v-update-sys-queue backup"
    "10 05 * * *|v-backup-users"
    "20 00 * * *|v-update-user-stats"
    "*/5 * * * *|v-update-sys-rrd"
    "__LE__|v-update-letsencrypt-ssl"
    "41 4 * * *|v-update-sys-hestia-all"
)

echo "============================================================"
echo " QemuCP - cola de reinicios y crons"
[ "$SOLO_VER" = "si" ] && echo " MODO VERIFICACION - no se cambia nada"
echo "============================================================"
echo ""

[ -d "$HESTIA/bin" ] || { bad "No parece una instalacion de QemuCP en $HESTIA"; exit 1; }
id hestiaweb >/dev/null 2>&1 || { bad "El usuario hestiaweb no existe: instalacion incompleta"; exit 1; }

PROBLEMAS=0

# ------------------------------------------------------- 1. servicio cron
echo "--- Servicio cron ---"
SRV="cron"
systemctl list-unit-files 2>/dev/null | grep -q "^crond" && SRV="crond"
if systemctl is-active --quiet "$SRV" 2>/dev/null; then
    ok "$SRV activo"
else
    bad "$SRV NO esta activo: ninguna tarea programada se ejecuta"
    PROBLEMAS=$((PROBLEMAS+1))
    if [ "$SOLO_VER" = "no" ]; then
        systemctl enable --now "$SRV" 2>/dev/null \
            && ok "$SRV arrancado y habilitado al inicio" \
            || bad "no se pudo arrancar $SRV"
    fi
fi

# --------------------------------------- 2. permisos del directorio spool
echo ""
echo "--- Directorio de crontabs ---"
SPOOL="/var/spool/cron/crontabs"
if [ -d "$SPOOL" ]; then
    MODO=$(stat -c '%a' "$SPOOL")
    if [ "$MODO" = "1730" ]; then
        ok "$SPOOL con permisos 1730"
    else
        warn "$SPOOL tiene permisos $MODO (lo normal es 1730)"
        [ "$SOLO_VER" = "no" ] && { chmod 1730 "$SPOOL"; chown root:crontab "$SPOOL" 2>/dev/null; ok "corregido a 1730"; }
    fi
else
    bad "$SPOOL no existe"
    PROBLEMAS=$((PROBLEMAS+1))
    [ "$SOLO_VER" = "no" ] && { mkdir -p "$SPOOL"; chmod 1730 "$SPOOL"; chown root:crontab "$SPOOL" 2>/dev/null; ok "creado"; }
fi

# ------------------------------------------------ 3. crontab de hestiaweb
echo ""
echo "--- Crontab de hestiaweb ---"
if [ ! -f "$CRONTAB" ]; then
    bad "$CRONTAB NO EXISTE: esta es la causa de que los dominios nuevos no resuelvan"
    PROBLEMAS=$((PROBLEMAS+1))
    if [ "$SOLO_VER" = "no" ]; then
        printf 'MAILTO=""\nCONTENT_TYPE="text/plain; charset=utf-8"\n' > "$CRONTAB"
        ok "creado con las cabeceras"
    fi
else
    ok "existe ($(grep -c "v-" "$CRONTAB" 2>/dev/null) tareas de QemuCP)"
fi

if [ -f "$CRONTAB" ]; then
    grep -q '^MAILTO=' "$CRONTAB" || {
        warn "falta la cabecera MAILTO"
        [ "$SOLO_VER" = "no" ] && sed -i '1i MAILTO=""' "$CRONTAB"
    }

    # Minuto y hora aleatorios para la renovacion de Let's Encrypt, igual que
    # hace HestiaCP: si todos los servidores renuevan a la misma hora, se
    # concentran las peticiones contra la CA.
    LE_MIN=$(( (RANDOM % 60) ))
    LE_HOUR=$(( (RANDOM % 7) + 1 ))

    FALTAN=0
    for T in "${TAREAS[@]}"; do
        HORARIO="${T%%|*}"
        CMD="${T##*|}"
        [ "$HORARIO" = "__LE__" ] && HORARIO="$LE_MIN $LE_HOUR * * *"
        if grep -qF "$CMD" "$CRONTAB" 2>/dev/null; then
            continue
        fi
        FALTAN=$((FALTAN+1))
        if [ "$SOLO_VER" = "si" ]; then
            warn "falta: $CMD"
        else
            echo "$HORARIO sudo $HESTIA/bin/$CMD" >> "$CRONTAB"
            ok "anadida: $CMD"
        fi
    done
    if [ "$FALTAN" -eq 0 ]; then
        ok "las 11 tareas estan presentes"
    else
        PROBLEMAS=$((PROBLEMAS+1))
    fi

    # ------------------------------------------- 4. propietario y permisos
    echo ""
    echo "--- Propietario y permisos del crontab ---"
    DUENO=$(stat -c '%U:%G' "$CRONTAB")
    MODO=$(stat -c '%a' "$CRONTAB")
    # Con otro propietario o con permisos de mas, cron descarta el fichero
    # sin registrar nada en ningun log.
    if [ "$DUENO" != "hestiaweb:hestiaweb" ] && [ "$DUENO" != "hestiaweb:crontab" ]; then
        bad "propietario $DUENO (cron lo ignora en silencio)"
        PROBLEMAS=$((PROBLEMAS+1))
        [ "$SOLO_VER" = "no" ] && { chown hestiaweb:hestiaweb "$CRONTAB"; ok "corregido a hestiaweb:hestiaweb"; }
    else
        ok "propietario $DUENO"
    fi
    if [ "$MODO" != "600" ]; then
        bad "permisos $MODO (deben ser 600)"
        PROBLEMAS=$((PROBLEMAS+1))
        [ "$SOLO_VER" = "no" ] && { chmod 600 "$CRONTAB"; ok "corregido a 600"; }
    else
        ok "permisos 600"
    fi
fi

# ----------------------------------------------- 5. sudoers de hestiaweb
echo ""
echo "--- Permiso sudo de hestiaweb ---"
if sudo -u hestiaweb -n "$HESTIA/bin/v-list-sys-config" >/dev/null 2>&1 \
   || grep -rq "hestiaweb.*$HESTIA/bin" /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
    ok "hestiaweb puede ejecutar los comandos del panel con sudo"
else
    bad "hestiaweb no puede usar sudo: las tareas fallarian aunque el cron corra"
    PROBLEMAS=$((PROBLEMAS+1))
    warn "revisa /etc/sudoers.d/hestia"
fi

# -------------------------------------------------- 6. cola pendiente
echo ""
echo "--- Cola de reinicios pendiente ---"
PIPE="$HESTIA/data/queue/restart.pipe"
if [ -s "$PIPE" ]; then
    warn "hay $(wc -l < "$PIPE") reinicio(s) sin aplicar:"
    sed 's/^/        /' "$PIPE" | head -5
    if [ "$SOLO_VER" = "no" ]; then
        "$HESTIA/bin/v-update-sys-queue" restart 2>/dev/null \
            && ok "cola procesada" || warn "no se pudo procesar la cola"
    fi
else
    ok "cola vacia"
fi

if [ "$SOLO_VER" = "no" ]; then
    systemctl restart "$SRV" 2>/dev/null && ok "$SRV reiniciado para releer el crontab"
fi

# ------------------------------------------------------------- resumen
echo ""
echo "============================================================"
if [ "$PROBLEMAS" -eq 0 ]; then
    echo -e " ${GREEN}Todo correcto.${NC} La cola de reinicios funciona: al crear una web,"
    echo " BIND y Nginx recargan solos en menos de 2 minutos."
elif [ "$SOLO_VER" = "si" ]; then
    echo -e " ${RED}$PROBLEMAS problema(s).${NC} Ejecuta sin --verificar para corregirlos:"
    echo "   bash $0"
else
    echo -e " ${GREEN}$PROBLEMAS problema(s) corregido(s).${NC}"
    echo ""
    echo " Compruebalo creando un dominio de prueba: debe resolver solo,"
    echo " sin que tengas que guardar la zona:"
    echo "   v-add-domain admin pruebacron.tudominio.com"
    echo "   sleep 150"
    echo "   dig +short A pruebacron.tudominio.com @127.0.0.1"
    echo "   v-delete-domain admin pruebacron.tudominio.com"
fi
echo "============================================================"
echo ""
echo "Atajo mientras tanto, tras crear cualquier web:"
echo "  v-restart-dns yes && v-restart-web yes && v-restart-proxy yes"
exit 0
QEMUCP_EMBED_CRON
chmod +x "$AUX_DIR"/*.sh
for S in instalar-hook.sh parche-subdominios.sh arreglar-crons.sh; do
    bash -n "$AUX_DIR/$S" || error "El script incrustado $S tiene un error de sintaxis"
done
log "3 scripts auxiliares desplegados en $AUX_DIR y verificados"

# ---------------------------------------------
#  PASO 1: PREPARAR SISTEMA BASE
# ---------------------------------------------
header "PASO 1: Preparando sistema base"

# --- Usuario/grupo 'admin' preexistente ----------------------------------
# hst-install aborta con "Username or Group allready exists" porque
# comprueba /etc/passwd Y /etc/group. Muchas imagenes de Ubuntu traen el
# grupo 'admin' (el antiguo grupo sudo) sin ningun usuario, y eso basta para
# bloquear la instalacion. Se resuelve aqui, antes de empezar.
# Solo en una instalacion NUEVA: HestiaCP crea el usuario 'admin', asi que al
# relanzar el script siempre existe y esta comprobacion lo haria abortar,
# impidiendo la recuperacion que el propio script promete.
if [[ ! -f /usr/local/hestia/conf/hestia.conf ]]; then
if getent passwd admin > /dev/null 2>&1; then
    error "Existe un usuario del sistema llamado 'admin' y QemuCP necesita ese nombre.
  No se borra automaticamente porque podria ser una cuenta real de acceso.
  Revisala y, si no la necesitas:  userdel -r admin
  Luego relanza este script."
fi
if getent group admin > /dev/null 2>&1; then
    # Solo se borra si esta vacio y no es el grupo primario de nadie
    MIEMBROS=$(getent group admin | cut -d: -f4)
    GID_ADMIN=$(getent group admin | cut -d: -f3)
    PRIMARIO=$(awk -F: -v g="$GID_ADMIN" '$4 == g {print $1}' /etc/passwd | head -1)
    if [[ -n "$MIEMBROS" ]]; then
        error "El grupo 'admin' existe y tiene miembros ($MIEMBROS).
  QemuCP necesita ese nombre. Quita los miembros o renombra el grupo, y relanza."
    elif [[ -n "$PRIMARIO" ]]; then
        error "El grupo 'admin' es el grupo primario del usuario '$PRIMARIO'.
  QemuCP necesita ese nombre. Resuelvelo y relanza."
    else
        groupdel admin 2>/dev/null \
            && log "Grupo 'admin' vacio eliminado (bloqueaba la instalacion)" \
            || warn "No se pudo eliminar el grupo 'admin': la instalacion puede abortar"
    fi
fi
fi   # fin de: solo en instalacion nueva

# En contenedores (y en algunos VPS minimos) systemd-timedated no esta
# disponible; con set -e, un fallo aqui abortaria toda la instalacion.
if ! timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
    ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime 2>/dev/null || true
    echo "$TIMEZONE" > /etc/timezone 2>/dev/null || true
fi
log "Timezone: $TIMEZONE"

# El locale ya se genero al inicio; solo persistir la config del sistema
update-locale LANG=es_ES.UTF-8 LC_ALL=es_ES.UTF-8 2>/dev/null || true
log "Locale: es_ES.UTF-8 (o C.UTF-8 si no disponible)"

# hostnamectl falla en contenedores (Docker monta /etc/hostname). Fuera de
# ellos funciona igual que antes.
if ! hostnamectl set-hostname "$HOSTNAME" 2>/dev/null; then
    hostname "$HOSTNAME" 2>/dev/null || true
    echo "$HOSTNAME" > /etc/hostname 2>/dev/null || true
fi
echo "127.0.0.1 $HOSTNAME" >> /etc/hosts
log "Hostname: $HOSTNAME"

apt-get update -qq
apt-get upgrade -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y -qq -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" \
    curl wget git unzip software-properties-common \
    apt-transport-https ca-certificates gnupg lsb-release \
    htop iotop net-tools dnsutils bc imagemagick \
    build-essential libpcre3-dev zlib1g-dev libssl-dev \
    libmaxminddb-dev libmaxminddb0 mmdb-bin || error "Fallo al instalar dependencias base del sistema"
log "Paquetes base instalados"

# PHP sera instalado y gestionado por HestiaCP en el PASO 2
# Bloqueamos las versiones obsoletas via apt ANTES de que HestiaCP las instale
add-apt-repository -y ppa:ondrej/php 2>/dev/null || true
apt-get update -qq

# Bloquear instalacion de versiones PHP EOL (5.6, 7.0, 7.1)
# HestiaCP con MultiPHP las instala automaticamente sin este bloqueo
if [ "$ALLOW_LEGACY_PHP" != "yes" ]; then
cat > /etc/apt/preferences.d/block-old-php << 'PINEOF'
Package: php5.6 php5.6-* libapache2-mod-php5.6
Pin: release *
Pin-Priority: -1

Package: php7.0 php7.0-* libapache2-mod-php7.0
Pin: release *
Pin-Priority: -1

Package: php7.1 php7.1-* libapache2-mod-php7.1
Pin: release *
Pin-Priority: -1
PINEOF
else
    warn "ALLOW_LEGACY_PHP=yes: PHP 5.6/7.0/7.1 NO bloqueadas (riesgo seguridad)"
fi
log "Versiones PHP obsoletas bloqueadas (5.6, 7.0, 7.1)"

# ---------------------------------------------
#  PASO 2: INSTALAR HESTIACP
# ---------------------------------------------
header "PASO 2: Instalando QemuCP"

# IDEMPOTENCIA: si el panel ya esta instalado (por ejemplo, una ejecucion
# anterior fallo DESPUES de instalar la base), saltamos la instalacion y
# vamos directos a las optimizaciones. Asi se puede relanzar el script sin
# reinstalar HestiaCP ni perder la configuracion existente.
# Detectar el SO siempre (se usa dentro y fuera del bloque de instalacion)
detect_os_type() {
    if [ -f /etc/debian_version ]; then
        if grep -qi ubuntu /etc/os-release 2>/dev/null; then echo "ubuntu"; else echo "debian"; fi
    else
        echo "ubuntu"
    fi
}
OS_TYPE=$(detect_os_type)

SKIP_BASE_INSTALL="no"
if [ -f /usr/local/hestia/conf/hestia.conf ] && [ -x /usr/local/hestia/bin/v-list-users ]; then
    EXISTING_VER=$(grep "^VERSION=" /usr/local/hestia/conf/hestia.conf 2>/dev/null | cut -d"'" -f2)
    warn "QemuCP/HestiaCP YA esta instalado (version ${EXISTING_VER:-desconocida})"
    warn "Se SALTA la instalacion base y se aplican solo las optimizaciones."
    warn "Si quieres una instalacion limpia, reinstala el sistema operativo."
    SKIP_BASE_INSTALL="yes"
fi

if [ "$SKIP_BASE_INSTALL" = "no" ]; then

cd /tmp || error "No se puede acceder a /tmp"
# QEMUCP_FORK_SRC=/ruta: usar una copia local del fork en lugar de descargar
# (la prueba automatica lo usa para instalar exactamente el commit probado).
if [[ -n "${QEMUCP_FORK_SRC:-}" ]]; then
    [[ -f "$QEMUCP_FORK_SRC/install/hst-install.sh" ]] || error "QEMUCP_FORK_SRC no contiene el fork: $QEMUCP_FORK_SRC"
    cp "$QEMUCP_FORK_SRC/install/hst-install.sh" hst-install.sh
    info "Usando el fork local: $QEMUCP_FORK_SRC"
else
    wget -q --timeout=30 "https://raw.githubusercontent.com/qemugen/qemucp/release/install/hst-install.sh" \
        -O hst-install.sh || error "No se pudo descargar el instalador de QemuCP"
fi

# Modificar textos de marca en el instalador usando sed (mas fiable)
sed -i \
    -e "s|Hestia Control Panel|QemuCP Control Panel|g" \
    -e "s|www\.hestiacp\.com|www.qemucp.com|g" \
    -e "s|1\.9\.[0-9][0-9]*|1.0|g" \
    hst-install.sh 2>/dev/null || true

# Reemplazar URL de descarga dentro de hst-install.sh para que use el fork
sed -i \
    -e "s|raw.githubusercontent.com/hestiacp/hestiacp/release/install|raw.githubusercontent.com/qemugen/qemucp/release/install|g" \
    hst-install.sh 2>/dev/null || true

# DEFENSA: forzar que hst-install.sh use el ubuntu.sh LOCAL ya parcheado
# en lugar de descargarlo (evita cache de GitHub Raw con version antigua).
# Descargamos ubuntu.sh nosotros con cache-buster y neutralizamos el version check.
CACHE_BUST=$(date +%s)
if [[ -n "${QEMUCP_FORK_SRC:-}" ]]; then
    cp "$QEMUCP_FORK_SRC/install/hst-install-${OS_TYPE}.sh" "hst-install-${OS_TYPE}.sh" \
        || error "No esta hst-install-${OS_TYPE}.sh en $QEMUCP_FORK_SRC"
else
    wget -q --timeout=30 "https://raw.githubusercontent.com/qemugen/qemucp/release/install/hst-install-${OS_TYPE}.sh?cb=${CACHE_BUST}" \
        -O "hst-install-${OS_TYPE}.sh" || error "No se pudo descargar hst-install-${OS_TYPE}.sh"
fi

# Neutralizar CUALQUIER version check que quede (defensa multi-capa)
# 1. Desactivar el bloque if del release_branch_ver
sed -i 's|if \[ "\$HESTIA_INSTALL_VER" != "\$release_branch_ver" \]; then|if false; then|g' \
    "hst-install-${OS_TYPE}.sh" 2>/dev/null || true
# 2. Por si acaso, forzar release_branch_ver = HESTIA_INSTALL_VER (nunca difieren)
sed -i 's|release_branch_ver=\$(curl.*|release_branch_ver="$HESTIA_INSTALL_VER"|g' \
    "hst-install-${OS_TYPE}.sh" 2>/dev/null || true

# Modificar hst-install.sh para que NO vuelva a descargar el ubuntu.sh (ya lo tenemos parcheado)
sed -i "s|wget -q https://raw.githubusercontent.com/qemugen/qemucp/release/install/hst-install-\$type.sh -O hst-install-\$type.sh|echo 'QemuCP: usando hst-install-'\$type'.sh local ya parcheado'|g" \
    hst-install.sh 2>/dev/null || true
sed -i "s|curl -s -O https://raw.githubusercontent.com/qemugen/qemucp/release/install/hst-install-\$type.sh|echo 'QemuCP: usando local'|g" \
    hst-install.sh 2>/dev/null || true

log "Instalador modificado: apunta al fork qemugen/qemucp (version check neutralizado)"

# ---------------------------------------------------------------------------
# PAQUETE hestia COMPILADO DESDE NUESTRO FORK
# ---------------------------------------------------------------------------
# Por defecto HestiaCP se instala desde apt.hestiacp.com. Eso significa que
# el panel que corre en el servidor NO es nuestro fork: es el de upstream, y
# cuando publican version nueva nos cambia los ficheros sin avisar (de ahi
# los bucles de login). Aqui compilamos el .deb de 'hestia' desde nuestra
# rama release con el compilador oficial (src/hst_autocompile.sh) y lo
# instalamos con --with-debs. hestia-nginx y hestia-php siguen viniendo de
# apt: son el nginx y el php internos del panel, no llevan nada nuestro.
#
# Para forzar la instalacion clasica desde apt:  QEMUCP_DESDE_APT=yes
FORK_REPO="https://github.com/qemugen/qemucp.git"
FORK_RAMA="release"
FORK_SRC="/opt/qemucp-src"
FORK_DEBS="/tmp/hestiacp-src/deb"
HST_ARGS_DEBS=()
INSTALADO_DESDE="apt"

if [[ "${QEMUCP_DESDE_APT:-no}" == "yes" ]]; then
    warn "QEMUCP_DESDE_APT=yes: se instala HestiaCP desde apt.hestiacp.com"
else
    info "Compilando el paquete hestia desde el fork ($FORK_RAMA)..."
    info "  (tarda unos minutos: instala Node y compila los assets del panel)"
    rm -rf "$FORK_SRC" "$FORK_DEBS"
    if [[ -n "${QEMUCP_FORK_SRC:-}" ]]; then
        CLON_OK="no"
        mkdir -p "$FORK_SRC" && cp -a "$QEMUCP_FORK_SRC/." "$FORK_SRC/" && CLON_OK="si"
    else
        CLON_OK="no"
        git clone -q --depth 1 -b "$FORK_RAMA" "$FORK_REPO" "$FORK_SRC" 2>/dev/null && CLON_OK="si"
    fi
    if [[ "$CLON_OK" == "si" ]]; then
        FORK_COMMIT=$(git -C "$FORK_SRC" rev-parse --short HEAD 2>/dev/null || echo "?")
        info "  fork clonado en el commit $FORK_COMMIT"
        # '~localsrc' = compilar desde la carpeta local, sin descargar nada mas
        ( cd "$FORK_SRC" && bash src/hst_autocompile.sh --hestia --noinstall --keepbuild '~localsrc' ) \
            > /var/log/qemucp-build.log 2>&1 || true
        # '|| true': si la compilacion fallo no hay .deb, ls devuelve 2 y con
        # pipefail la asignacion abortaria el script antes de caer a apt.
        DEB_HESTIA=$(ls -1 "$FORK_DEBS"/hestia_*.deb 2>/dev/null | head -1 || true)
        if [[ -n "$DEB_HESTIA" ]] && dpkg-deb -I "$DEB_HESTIA" >/dev/null 2>&1; then
            DEB_VER=$(dpkg-deb -f "$DEB_HESTIA" Version 2>/dev/null)
            log "Paquete hestia $DEB_VER compilado desde el fork ($FORK_COMMIT)"
            HST_ARGS_DEBS=(-D "$FORK_DEBS")
            INSTALADO_DESDE="fork"
        else
            warn "La compilacion desde el fork fallo (ver /var/log/qemucp-build.log)"
            warn "Se continua con el paquete de apt.hestiacp.com"
        fi
    else
        warn "No se pudo clonar $FORK_REPO: se usa el paquete de apt"
    fi
fi

bash hst-install.sh \
    "${HST_ARGS_DEBS[@]}" \
    -y no \
    -e "$ADMIN_EMAIL" \
    -p "$ADMIN_PASS" \
    -s "$HOSTNAME" \
    -u "admin" \
    -a yes \
    -o yes \
    -v yes \
    -j no \
    -k yes \
    -m yes \
    -g no \
    -x yes \
    -z yes \
    -t yes \
    -c yes \
    -i yes \
    -b yes \
    -q no \
    -d yes \
    -l "$HESTIA_LANG" \
    -r "$HESTIA_PORT" \
    -f

log "QemuCP instalado correctamente"

if [[ "$INSTALADO_DESDE" == "fork" ]]; then
    # Sin esto, el primer 'apt upgrade' cambiaria nuestro paquete por el de
    # upstream y volveriamos al punto de partida.
    apt-mark hold hestia >/dev/null 2>&1 \
        && log "Paquete hestia bloqueado (apt-mark hold): solo se actualiza desde el fork" \
        || warn "No se pudo bloquear el paquete hestia: un apt upgrade lo sustituiria"
    echo "fork $FORK_COMMIT $(date '+%F %T')" > /usr/local/hestia/conf/qemucp-origen 2>/dev/null || true
else
    echo "apt $(date '+%F %T')" > /usr/local/hestia/conf/qemucp-origen 2>/dev/null || true
fi

# ---------------------------------------------
#  VERIFICACION CRITICA: coherencia de version
# ---------------------------------------------
# El paquete .deb de HestiaCP (apt.hestiacp.com) puede ir por delante del fork.
# Si la version instalada != version del fork, los ficheros de sesion
# (main.php, login, list/user) que trae el paquete son INCOHERENTES con los
# del fork -> login loop / array_reverse(null). Detectamos y avisamos.
INSTALLED_HESTIA_VER=$(grep "^VERSION=" /usr/local/hestia/conf/hestia.conf 2>/dev/null | cut -d"'" -f2)
# La version del fork se lee del hst-install-${OS_TYPE}.sh que descargamos antes.
# NO usar $HESTIA_INSTALL_VER: esa variable solo existe DENTRO de ese script,
# no aqui, y con 'set -u' referenciarla aborta la instalacion.
FORK_HESTIA_VER=""
for CAND in "/tmp/hst-install-${OS_TYPE:-ubuntu}.sh" "./hst-install-${OS_TYPE:-ubuntu}.sh"; do
    if [ -f "$CAND" ]; then
        FORK_HESTIA_VER=$(grep "^HESTIA_INSTALL_VER=" "$CAND" 2>/dev/null | head -1 | cut -d"'" -f2)
        [ -n "$FORK_HESTIA_VER" ] && break
    fi
done
if [ -n "$INSTALLED_HESTIA_VER" ] && [ -n "$FORK_HESTIA_VER" ] && [ "$INSTALLED_HESTIA_VER" != "$FORK_HESTIA_VER" ]; then
    warn "================================================================"
    warn "AVISO DE VERSION: paquete instalado ($INSTALLED_HESTIA_VER) != fork ($FORK_HESTIA_VER)"
    warn "HestiaCP publico una version nueva. Los ficheros de sesion del"
    warn "PAQUETE (main.php, login, list/user) mandan y son coherentes entre"
    warn "si, asi que el LOGIN FUNCIONARA. Pero las personalizaciones del"
    warn "panel (WP-TOOL, Performance) pueden no aparecer hasta sincronizar"
    warn "el fork a $INSTALLED_HESTIA_VER."
    warn "El instalador NO sobrescribe main.php/login/list_user del fork,"
    warn "para no romper el login. Sincroniza el fork cuando puedas."
    warn "================================================================"
    # Marcar para que los pasos de branding NO toquen ficheros de sesion
    VERSION_MISMATCH="yes"
else
    log "Version coherente: $INSTALLED_HESTIA_VER (fork y paquete coinciden)"
    VERSION_MISMATCH="no"
fi

fi   # fin de: if [ "$SKIP_BASE_INSTALL" = "no" ]

# Eliminar instalador base tras la instalacion (el autoborrado del script va al final)
rm -f /tmp/hst-install.sh 2>/dev/null || true
log "Instalador base eliminado"

source /usr/local/hestia/conf/hestia.conf 2>/dev/null || true
HESTIA=/usr/local/hestia

# ---------------------------------------------
#  PASO 2C: IDIOMA ESPANOL + TEMA DARK
# ---------------------------------------------
header "PASO 2C: Forzando idioma Espanol + tema Dark"

$HESTIA/bin/v-change-user-language admin es 2>/dev/null && \
    log "Idioma admin: Espanol" || warn "Idioma admin: configura manualmente"
$HESTIA/bin/v-change-user-theme admin flat 2>/dev/null && \
    log "Tema admin: Dark" || warn "Tema admin: configura manualmente"

HESTIA_CONF="$HESTIA/conf/hestia.conf"
if grep -q "^LANGUAGE=" "$HESTIA_CONF" 2>/dev/null; then
    sed -i "s/^LANGUAGE=.*/LANGUAGE='es'/" "$HESTIA_CONF"
else
    echo "LANGUAGE='es'" >> "$HESTIA_CONF"
fi
log "Idioma global del panel: Espanol"

# Hook post-creacion: nuevos usuarios heredan es + dark automaticamente
HOOK_DIR="$HESTIA/data/hooks"
mkdir -p "$HOOK_DIR"
cat > "$HOOK_DIR/post_add_user.sh" << 'HOOKEOF'
#!/bin/bash
HESTIA=/usr/local/hestia
NEW_USER="$1"
[[ -z "$NEW_USER" ]] && exit 0
$HESTIA/bin/v-change-user-language "$NEW_USER" es 2>/dev/null || true
$HESTIA/bin/v-change-user-theme "$NEW_USER" flat 2>/dev/null || true
HOOKEOF
chmod +x "$HOOK_DIR/post_add_user.sh" 2>/dev/null || true
# NOTA: data/hooks/post_add_user.sh tampoco lo ejecuta HestiaCP. Se deja
# escrito por si una version futura lo soporta, pero lo que de verdad hace
# que los usuarios nuevos salgan en espanol es LANGUAGE='es' en
# hestia.conf (se fija mas arriba): v-add-user escribe LANGUAGE='' en el
# user.conf, que significa "heredar del sistema".
log "Hook post-creacion escrito (el idioma real lo fija LANGUAGE en hestia.conf)"

# ---------------------------------------------
#  NOTA SOBRE EL HOOK DE POST-ACTUALIZACION
# ---------------------------------------------
# Aqui habia un post_update.sh de ~90 lineas que reaplicaba la marca tras
# cada actualizacion. Se escribia en $HESTIA/data/hooks/, una ruta que
# HestiaCP NO EJECUTA NUNCA: el unico hook es
#   /etc/hestiacp/hooks/post_install.sh
# llamado al final del postinst del paquete hestia. Por eso la marca y los
# parches se perdian en cada apt upgrade sin que nada lo avisara.
# Ahora lo instala el PASO 10C mediante install/instalar-hook.sh, que
# ademas de la marca reaplica los parches propios. No recrear aqui un
# post_update.sh: seria codigo muerto.


# ---------------------------------------------
#  PASO 3: PERSONALIZACION DE MARCA (QemuCP)
# ---------------------------------------------
header "PASO 3: Aplicando personalizacion QemuCP"

THEME_DIR="$HESTIA/web/css"
WEB_DIR="$HESTIA/web"

# Guardar copia de seguridad del CSS para que el hook post-update pueda restaurarlo
cp "$THEME_DIR/custom-brand.css" "$THEME_DIR/custom-brand.css.qemucp" 2>/dev/null || true

mkdir -p "$WEB_DIR/images/custom"
if wget -q --timeout=30 "$BRAND_LOGO" -O "$WEB_DIR/images/custom/brand-logo.png" 2>/dev/null; then
    log "Logo descargado desde el fork"
elif wget -q --timeout=30 "$BRAND_LOGO_FALLBACK" -O "$WEB_DIR/images/custom/brand-logo.png" 2>/dev/null; then
    log "Logo descargado desde zonasdnsprivadas.com (fallback)"
else
    warn "No se pudo descargar el logo - se usara el logo por defecto"
fi

if command -v convert &>/dev/null; then
    convert "$WEB_DIR/images/custom/brand-logo.png" \
        -background none -resize 32x32 "$WEB_DIR/images/favicon.ico" 2>/dev/null || true
    convert "$WEB_DIR/images/custom/brand-logo.png" \
        -background none -resize 180x180 "$WEB_DIR/images/apple-touch-icon.png" 2>/dev/null || true
    log "Favicon y apple-touch-icon generados"
fi

cat > "$THEME_DIR/custom-brand.css" << 'CSSEOF'
/* =============================================
   QemuCP - Custom Brand (flat theme)
   Logo PNG con fondo transparente
   ============================================= */

/* Ocultar referencias a HestiaCP */
a[href*="hestiacp.com"],
.powered-by-hestia,
[title="HestiaCP"],
.hestia-brand { display: none !important; }

/* -- Logo en sidebar / header -- */
/* Los logos se sirven directamente desde /images/logo-header.svg y /images/logo.svg */
/* descargados del fork qemugen/qemucp con fondo transparente y colores correctos */

/* Asegurar tamanios correctos */
.top-bar-logo img {
    height: 36px !important;
    width: auto !important;
}

.login img[src*="logo"] {
    max-width: 260px !important;
    height: auto !important;
    display: block !important;
    margin: 0 auto 24px auto !important;
}

/* -- Titulo -- */
.brand-name::after { content: "QemuCP" !important; }

/* -- Footer -- */
footer .brand,
.footer-brand { visibility: hidden !important; }
footer .footer-brand::after,
footer .brand::after {
    content: "QemuCP Control Panel";
    visibility: visible !important;
    font-size: 0.82em;
    opacity: 0.55;
}
CSSEOF
log "CSS de marca creado"

find "$WEB_DIR" \( -name "*.php" -o -name "*.html" -o -name "*.tpl" \) \
    -not -path "*/node_modules/*" 2>/dev/null | while read -r f; do
    sed -i \
        -e 's|Hestia Control Panel|QemuCP Control Panel|g' \
        -e 's|HestiaCP|QemuCP|g' \
        -e 's|Hestia CP|QemuCP|g' \
        -e 's|hestiacp\.com|qemucp.com|g' \
        "$f" 2>/dev/null || true
done
log "Referencias de marca reemplazadas"

# Descargar logos QemuCP directamente desde el fork
FORK_RAW="https://raw.githubusercontent.com/qemugen/qemucp/release/web/images"
log "Instalando logos QemuCP..."

# Logo del panel superior (barra de navegacion)
wget -q --timeout=30 "$FORK_RAW/logo-header.svg"     -O "$WEB_DIR/images/logo-header.svg" 2>/dev/null &&     log "logo-header.svg instalado" || warn "No se pudo descargar logo-header.svg"

# Logo de la pagina de login
wget -q --timeout=30 "$FORK_RAW/logo.svg"     -O "$WEB_DIR/images/logo.svg" 2>/dev/null &&     log "logo.svg instalado" || warn "No se pudo descargar logo.svg"

# Logo PNG de fallback
wget -q --timeout=30 "$FORK_RAW/logo.png"     -O "$WEB_DIR/images/logo.png" 2>/dev/null || true

# Favicon
wget -q --timeout=30 "$FORK_RAW/favicon.png"     -O "$WEB_DIR/images/favicon.png" 2>/dev/null || true

log "Logos QemuCP instalados correctamente"


# Establecer APP_NAME en hestia.conf para el panel
# Ruta REAL: /usr/local/hestia/conf/hestia.conf (NO /etc/hestiacp/ que no siempre existe)
HESTIA_CONF="/usr/local/hestia/conf/hestia.conf"
if grep -q "^APP_NAME=" "$HESTIA_CONF" 2>/dev/null; then
    sed -i "s|APP_NAME=.*|APP_NAME='QemuCP Control Panel'|" "$HESTIA_CONF"
else
    echo "APP_NAME='QemuCP Control Panel'" >> "$HESTIA_CONF"
fi
log "APP_NAME configurado como QemuCP Control Panel"

# Instalar Quick Install optimizados de QemuCP
FORK_RAW="https://raw.githubusercontent.com/qemugen/qemucp/release"
INSTALLERS_DIR="$HESTIA/web/src/app/WebApp/Installers"

# WordPress Optimizado
mkdir -p "$INSTALLERS_DIR/WordPressOptimized"
wget -q --timeout=30     "$FORK_RAW/web/src/app/WebApp/Installers/WordPressOptimized/WordPressOptimizedSetup.php"     -O "$INSTALLERS_DIR/WordPressOptimized/WordPressOptimizedSetup.php" &&     log "WordPress Optimizado (QemuCP) instalado" ||     warn "No se pudo instalar WordPress Optimizado"
wget -q --timeout=30     "$FORK_RAW/web/src/app/WebApp/Installers/WordPressOptimized/wp-qemucp-thumb.png"     -O "$INSTALLERS_DIR/WordPressOptimized/wp-qemucp-thumb.png" 2>/dev/null || true

# PrestaShop Optimizado
mkdir -p "$INSTALLERS_DIR/PrestaShopOptimized"
wget -q --timeout=30     "$FORK_RAW/web/src/app/WebApp/Installers/PrestaShopOptimized/PrestaShopOptimizedSetup.php"     -O "$INSTALLERS_DIR/PrestaShopOptimized/PrestaShopOptimizedSetup.php" &&     log "PrestaShop Optimizado (QemuCP) instalado" ||     warn "No se pudo instalar PrestaShop Optimizado"
wget -q --timeout=30     "$FORK_RAW/web/src/app/WebApp/Installers/PrestaShopOptimized/ps-qemucp-thumb.png"     -O "$INSTALLERS_DIR/PrestaShopOptimized/ps-qemucp-thumb.png" 2>/dev/null || true



for HEADER_FILE in "$WEB_DIR/templates/header.php" "$WEB_DIR/templates/header.html"; do
    if [[ -f "$HEADER_FILE" ]] && ! grep -q "custom-brand.css" "$HEADER_FILE"; then
        sed -i 's|</head>|    <link rel="stylesheet" href="/css/custom-brand.css">\n</head>|' "$HEADER_FILE"
        log "CSS inyectado en $(basename $HEADER_FILE)"
    fi
done

for LOGIN_FILE in "$WEB_DIR/templates/login.html" "$WEB_DIR/templates/login.php"; do
    [[ -f "$LOGIN_FILE" ]] || continue
    sed -i \
        's|<img[^>]*hestia[^>]*logo[^>]*>|<img src="/images/custom/brand-logo.png" alt="QemuCP" style="max-width:200px;max-height:72px;display:block;margin:0 auto 28px auto;">|gi' \
        "$LOGIN_FILE" 2>/dev/null || true
done
log "Logo de login actualizado"

# ---------------------------------------------
#  PASO 4: GEOIP2 + MODULO NGINX DINAMICO
# ---------------------------------------------
header "PASO 4: Compilando e instalando modulo GeoIP2 para Nginx"

# Obtener version exacta de Nginx instalado por HestiaCP
NGINX_VER=$(nginx -v 2>&1 | grep -oP '[\d.]+$')
log "Nginx detectado: $NGINX_VER"

# Dependencias de compilacion
apt-get install -y -qq \
    libmaxminddb-dev libmaxminddb0 mmdb-bin \
    build-essential libpcre3-dev zlib1g-dev libssl-dev \
    libgd-dev libgeoip-dev || warn "Algunas dependencias GeoIP2 no se instalaron"

# Compilar el modulo dinamico ngx_http_geoip2 (OPCIONAL - no aborta si falla)
# GEOIP2_MODULE controla si despues se carga en nginx.conf
GEOIP2_MODULE="no"
NGINX_VER_DETECTED=$(nginx -v 2>&1 | grep -oP 'nginx/\K[0-9.]+' || echo "$NGINX_VER")
[ -n "$NGINX_VER_DETECTED" ] && NGINX_VER="$NGINX_VER_DETECTED"

if rm -rf /root/tmp_geoip && mkdir -p /root/tmp_geoip && cd /root/tmp_geoip \
   && wget -q --timeout=30 "http://nginx.org/download/nginx-${NGINX_VER}.tar.gz" 2>/dev/null \
   && tar -xzf "nginx-${NGINX_VER}.tar.gz" 2>/dev/null \
   && git clone --depth 1 https://github.com/leev/ngx_http_geoip2_module.git 2>/dev/null; then

    CONFARGS=$(nginx -V 2>&1 | grep "configure arguments:" | sed 's/configure arguments: //')
    if cd "/root/tmp_geoip/nginx-${NGINX_VER}" 2>/dev/null \
       && eval "./configure --with-compat ${CONFARGS} --add-dynamic-module=/root/tmp_geoip/ngx_http_geoip2_module" >/dev/null 2>&1 \
       && make -j$(nproc) modules >/dev/null 2>&1 \
       && mkdir -p /etc/nginx/modules \
       && cp objs/ngx_http_geoip2_module.so /etc/nginx/modules/ 2>/dev/null; then
        chmod 644 /etc/nginx/modules/ngx_http_geoip2_module.so 2>/dev/null || true
        GEOIP2_MODULE="yes"
        log "Modulo ngx_http_geoip2_module.so compilado e instalado"
    else
        warn "No se pudo compilar el modulo GeoIP2 - se instalara SIN bloqueo por pais"
    fi
else
    warn "No se pudieron obtener las fuentes para GeoIP2 - se instalara SIN bloqueo por pais"
fi

# El modulo se carga directamente en nginx.conf (ver PASO 5)
# No creamos 50-geoip2.conf para evitar carga duplicada
log "Modulo GeoIP2 se cargara desde nginx.conf"

# Base de datos GeoIP2 (opcional - solo para bloqueo por pais)
# NUNCA aborta la instalacion; si falla, GeoIP queda deshabilitado y se avisa.
mkdir -p /usr/share/GeoIP
log "Descargando base de datos GeoIP2-Country..."
GEOIP_OK="no"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36"

# Fuente 1 (primaria): copia propia en zonasdnsprivadas.com
if wget -q --timeout=30 --user-agent="$UA" \
        "https://zonasdnsprivadas.com/scripts/nginx/GeoIP2-Country.mmdb" \
        -O /usr/share/GeoIP/GeoIP2-Country.mmdb 2>/dev/null \
    && [ -s /usr/share/GeoIP/GeoIP2-Country.mmdb ]; then
    log "GeoIP2-Country.mmdb instalada desde zonasdnsprivadas.com"
    GEOIP_OK="yes"
fi

# Fuente 2 (fallback): db-ip.com (mes actual y anterior)
if [ "$GEOIP_OK" = "no" ]; then
    for M in "$(date +%Y-%m)" "$(date -d '1 month ago' +%Y-%m 2>/dev/null || date +%Y-%m)"; do
        if wget -q --timeout=30 --user-agent="$UA" \
                "https://download.db-ip.com/free/dbip-country-lite-${M}.mmdb.gz" \
                -O /tmp/dbip-country.mmdb.gz 2>/dev/null \
            && gunzip -f /tmp/dbip-country.mmdb.gz 2>/dev/null \
            && mv /tmp/dbip-country.mmdb /usr/share/GeoIP/GeoIP2-Country.mmdb 2>/dev/null; then
            log "GeoIP2-Country.mmdb instalada desde DB-IP (${M})"
            GEOIP_OK="yes"
            break
        fi
    done
fi

if [ "$GEOIP_OK" = "no" ]; then
    warn "GeoIP2 no se pudo descargar automaticamente."
    warn "El panel funciona igual; el bloqueo por pais quedara inactivo hasta"
    warn "colocar manualmente /usr/share/GeoIP/GeoIP2-Country.mmdb"
fi

# ---------------------------------------------
#  PASO 4A: FICHEROS DE CONFIGURACION GEOIP2
# ---------------------------------------------
header "PASO 4A: Creando configuracion GeoIP2 para QemuCP/Nginx"

mkdir -p /etc/nginx/conf.d/lists
mkdir -p /etc/nginx/conf.d/server-includes

# -- 00-init.conf: variables GeoIP2 -------------------------------------------
# El bloque 'geoip2' referencia el .mmdb. Si ese fichero NO existe, nginx NO
# arranca y el panel/webs quedan caidos. Por eso el bloque geoip2 solo se
# escribe si la base de datos se descargo correctamente.
cat > /etc/nginx/conf.d/00-init.conf << 'EOF'
# QemuCP - GeoIP2 Init
# Detecta la IP real detras de proxies/CDN
map $http_x_forwarded_for $realip {
    ~^(\d+\.\d+\.\d+\.\d+) $1;
    default $remote_addr;
}
EOF

if [ -s /usr/share/GeoIP/GeoIP2-Country.mmdb ]; then
    cat >> /etc/nginx/conf.d/00-init.conf << 'EOF'

geoip2 /usr/share/GeoIP/GeoIP2-Country.mmdb {
    auto_reload 5m;
    $geoip2_data_country_code default=US source=$realip country iso_code;
    $geoip2_data_country_name source=$realip country names en;
}
EOF
    log "00-init.conf creado (con GeoIP2 activo)"
else
    # Sin base de datos: definir la variable con valor por defecto para que
    # los 'map' que la usan mas abajo no fallen (nginx exige que exista).
    cat >> /etc/nginx/conf.d/00-init.conf << 'EOF'

# GeoIP2 no disponible - variable con valor por defecto para no romper los maps
map $realip $geoip2_data_country_code {
    default "ES";
}
EOF
    warn "00-init.conf creado SIN GeoIP2 (base de datos no disponible)"
    warn "El bloqueo por pais quedara inactivo (todo el trafico se trata como ES)"
fi

# -- 01-maps.conf: logica de bloqueo ------------------------------------------
cat > /etc/nginx/conf.d/01-maps.conf << 'EOF'
# QemuCP - GeoIP2 Maps & Bot Detection

# 1. Whitelist de IPs de confianza
map $realip $is_ip_whitelisted {
    default 0;
    include /etc/nginx/conf.d/lists/whitelist.list;
}

# 2. Pais de confianza base (Espana)
map $geoip2_data_country_code $is_spain {
    default 0;
    "ES"    1;
}

# 3. Confianza agregada: Espana O IP whitelisted
map "$is_ip_whitelisted:$is_spain" $is_trusted {
    "~1"    1;
    default 0;
}

# 4. Deteccion de bots por User-Agent
map $http_user_agent $bot_type_raw {
    default "unknown";
    ""      "badbot";
    include /etc/nginx/conf.d/lists/bots.list;
}

map $bot_type_raw $bot_type {
    default $bot_type_raw;
}

# 5. Logica de rechazo de URIs
# Formato: "is_ip_whitelisted:is_trusted:request_uri"
map "$is_ip_whitelisted:$is_trusted:$request_uri" $uri_reject {
    # 5.1. Bypass para IPs whitelisted
    "~^1:"                          0;
    # 5.2. XMLRPC: bloquear para todos salvo IP whitelist (incluye Espana)
    "~^0:[^:]*:.*xmlrpc\.php"       444;
    # 5.3. Doble slash al inicio: solo bloquear si no es trusted
    "~^0:0://+"                     444;
    default                         0;
}

# 6. Rechazo de bots (bypass para Espana e IPs whitelist)
map "$is_trusted:$bot_type_raw" $bot_reject {
    "~^0:badbot"    1;
    default         0;
}

# 7. Bloqueo GeoIP (451 Legal Block)
map $geoip2_data_country_code $allowed_country_raw {
    default yes;
    include /etc/nginx/conf.d/lists/countries.list;
}

map "$is_trusted:$allowed_country_raw" $allowed_country_final {
    "~^1:"  "yes";
    default $allowed_country_raw;
}

# 8. SEO y rate limiting para Googlebot
map $bot_type_raw $limit_google {
    "google" "bot";
    default  "";
}

map $request_uri $x_robots_tag {
    default "";
    ~[\?&](q=|resultsPerPage=|productListView=|order=|p=) "noindex, follow";
}

map "$bot_type_raw|$args" $gb_facet_410 {
    default 0;
    ~^google\|.*(?:^|&)(?:q|resultsPerPage|productListView|order|p)= 1;
}

limit_req_status 429;
limit_req_zone $limit_google zone=googlebot_slow:10m rate=30r/m;
EOF
log "01-maps.conf creado"

# -- 02-logging.conf: formato de log extendido ---------------------------------
# 02-logging.conf: el log_format esta definido en nginx.conf
# Solo mantenemos el log de acceso especifico de GeoIP2
cat > /etc/nginx/conf.d/02-logging.conf << 'EOF'
# QemuCP - Log de acceso completo con GeoIP2 (acceso a todos los sitios)
# El formato main_ext esta definido en nginx.conf
EOF
log "02-logging.conf creado"

# -- main-rules.conf: reglas activas por vhost --------------------------------
mkdir -p /etc/nginx/conf.d/server-includes
cat > /etc/nginx/conf.d/server-includes/main-rules.conf << 'EOF'
# QemuCP - Reglas GeoIP2 activas (incluir dentro de cada server{})
#
# Uso en vhost QemuCP: anadir en la seccion server{}
#   include /etc/nginx/conf.d/server-includes/main-rules.conf;
#
# Las lineas de debug se pueden activar temporalmente:
#add_header X-Debug-Trusted $is_trusted always;
#add_header X-Debug-Reject  $uri_reject always;
#add_header X-Debug-Country $geoip2_data_country_code always;

# 1. Rechazo inmediato (444 Connection Close - sin respuesta al cliente)
if ($bot_reject) { return 444; }
if ($uri_reject) { return 444; }

# 2. Bloqueo GeoIP (451 - No disponible por razones legales)
if ($allowed_country_final = "no") { return 451; }

# 3. SEO: noindex en parametros de busqueda/facetas
add_header X-Robots-Tag $x_robots_tag always;

# 4. 410 Gone para Googlebot en facetas indexadas
if ($gb_facet_410) { return 410; }

# 5. Normalizacion: redirigir resultsPerPage masivos a 24
if ($arg_resultsPerPage ~ '^9{3,}$') {
    return 301 $scheme://$host$uri?resultsPerPage=24;
}

# 6. Rate limiting Googlebot + log condicional
limit_req zone=googlebot_slow burst=5 nodelay;
access_log /var/log/nginx/access_all.log combined if=$loggable;
EOF
log "server-includes/main-rules.conf creado"

# -- Listas: paises bloqueados -------------------------------------------------
cat > /etc/nginx/conf.d/lists/countries.list << 'EOF'
# QemuCP - Paises bloqueados (GeoIP2)
# Formato: "CODIGO_ISO" no;
# Anade o elimina segun necesites
RU no;
UA no;
VN no;
SG no;
CN no;
JP no;
IN no;
KR no;
MD no;
EOF
log "countries.list creado (RU, UA, VN, SG, CN, JP, IN, KR, MD)"

# -- Listas: bots --------------------------------------------------------------
cat > /etc/nginx/conf.d/lists/bots.list << 'EOF'
# QemuCP - Lista de bots
# Formato: "~*NombreBot" "tipo";
# tipo "google"  -> permitido pero con rate limiting
# tipo "badbot"  -> bloqueado con 444
"~*Googlebot"                "google";
"~*SemrushBot"               "badbot";
"~*AhrefsBot"                "badbot";
"~*GPTBot"                   "badbot";
"~*OpenAI"                   "badbot";
"~*TikTokSpider"             "badbot";
"~*Bytespider"               "badbot";
"~*SERankingBacklinksBot"    "badbot";
"~*MJ12bot"                  "badbot";
"~*DotBot"                   "badbot";
"~*BLEXBot"                  "badbot";
"~*PetalBot"                 "badbot";
"~*YandexBot"                "badbot";
EOF
log "bots.list creado"

# -- Listas: IPs en whitelist --------------------------------------------------
cat > /etc/nginx/conf.d/lists/whitelist.list << 'EOF'
# QemuCP - IPs en whitelist (siempre permitidas, bypass GeoIP y bots)
# Formato: IP 1;
# Anade aqui las IPs de tu equipo, oficina, etc.
78.128.8.207 1;
127.0.0.1    1;
EOF
log "whitelist.list creado"

# -- Integrar GeoIP2 en la plantilla de vhosts de HestiaCP --------------------
# HestiaCP genera los vhosts desde templates. Anadimos el include de GeoIP2
# en los templates de Nginx para que cada nuevo sitio lo herede automaticamente.
NGINX_TPL_DIR="$HESTIA/data/templates/web/nginx"
for TPL in "$NGINX_TPL_DIR"/*.tpl "$NGINX_TPL_DIR"/*.stpl; do
    [[ -f "$TPL" ]] || continue
    # Solo anadir si no esta ya incluido
    if ! grep -q "main-rules.conf" "$TPL" 2>/dev/null; then
        # Insertar el include dentro del bloque server{} tras la primera llave
        sed -i '/^server[[:space:]]*{/a\    # QemuCP GeoIP2 rules\n    include /etc/nginx/conf.d/server-includes/main-rules.conf;' "$TPL"
    fi
done
log "main-rules.conf incluido en templates de vhost QemuCP"

# Aplicar tambien a los vhosts ya existentes (admin y panel)
for VHOST in /etc/nginx/conf.d/*.conf /etc/nginx/sites-enabled/*; do
    [[ -f "$VHOST" ]] || continue
    [[ "$VHOST" == *"geoip"* ]] && continue
    [[ "$VHOST" == *"00-init"* ]] && continue
    [[ "$VHOST" == *"01-maps"* ]] && continue
    [[ "$VHOST" == *"02-logging"* ]] && continue
    if grep -q "server\s*{" "$VHOST" 2>/dev/null && \
       ! grep -q "main-rules.conf" "$VHOST" 2>/dev/null; then
        sed -i '/^server[[:space:]]*{/a\    include /etc/nginx/conf.d/server-includes/main-rules.conf;' "$VHOST"
    fi
done
log "main-rules.conf incluido en vhosts existentes"

# Limpiar archivos temporales de compilacion
rm -rf /root/tmp_geoip
log "Archivos temporales de compilacion eliminados"

# ---------------------------------------------
#  PASO 5: OPTIMIZACION NGINX + GEOIP2
# ---------------------------------------------
header "PASO 5: Optimizando Nginx de QemuCP"

# Backup del nginx.conf original de HestiaCP
cp /etc/nginx/nginx.conf /etc/nginx/nginx.conf.bak.$(date +%Y%m%d) 2>/dev/null || true

# Anadir load_module GeoIP2 SOLO si el modulo se compilo (GEOIP2_MODULE=yes)
# Cargar un .so inexistente impediria que nginx arranque.
if [ "${GEOIP2_MODULE:-no}" = "yes" ] && [ -f /etc/nginx/modules/ngx_http_geoip2_module.so ]; then
    if ! grep -q "ngx_http_geoip2_module" /etc/nginx/nginx.conf 2>/dev/null; then
        { echo "load_module modules/ngx_http_geoip2_module.so;"; cat /etc/nginx/nginx.conf; } > /tmp/nginx_geoip_tmp.conf && \
        mv /tmp/nginx_geoip_tmp.conf /etc/nginx/nginx.conf && \
        log "GeoIP2 load_module anadido" || \
        warn "No se pudo anadir GeoIP2 load_module"
    else
        log "GeoIP2 load_module ya presente en nginx.conf"
    fi
else
    warn "GeoIP2 no compilado - se omite load_module (nginx arrancara sin GeoIP2)"
fi

# Crear fichero de optimizaciones en conf.d
# HestiaCP incluye /etc/nginx/conf.d/*.conf dentro del bloque http{}
# asi que estas directivas se aplican sin tocar nginx.conf
cat > /etc/nginx/conf.d/99-qemucp-performance.conf << 'PERFEOF'
# QemuCP - Optimizaciones de rendimiento Nginx
# Solo directivas que HestiaCP no define para evitar duplicados

# Map para log condicional (excluir assets estaticos)
# NOTA: limit_req_zone login/api ya definidos en nginx.conf de HestiaCP
map $uri $loggable {
    default                                                    1;
    "~*\.(ico|css|js|gif|jpe?g|png|woff2?|svg|otf|ttf|eot|webp|mp4)$" 0;
}
PERFEOF
log "Optimizaciones Nginx aplicadas via conf.d"

# Workers segun CPUs disponibles
CPU_CORES=$(nproc)
if grep -q "worker_processes" /etc/nginx/nginx.conf 2>/dev/null; then
    sed -i "s|worker_processes.*|worker_processes $CPU_CORES;|" /etc/nginx/nginx.conf
    log "Nginx worker_processes ajustado a $CPU_CORES cores"
fi

# Aumentar limite de ficheros abiertos
if grep -q "worker_rlimit_nofile" /etc/nginx/nginx.conf 2>/dev/null; then
    sed -i "s|worker_rlimit_nofile.*|worker_rlimit_nofile 65535;|" /etc/nginx/nginx.conf
else
    sed -i "/worker_processes/a worker_rlimit_nofile 65535;" /etc/nginx/nginx.conf
fi

# Worker connections
if grep -q "worker_connections" /etc/nginx/nginx.conf 2>/dev/null; then
    sed -i "s|worker_connections.*|worker_connections 4096;|" /etc/nginx/nginx.conf
fi

# Ajustar directivas que HestiaCP define en nginx.conf
# Usamos sed para modificarlas en su sitio original sin duplicarlas
NGINX_CONF="/etc/nginx/nginx.conf"

# client_max_body_size -> 256m para WordPress/PrestaShop
sed -i "s|client_max_body_size[^;]*;|client_max_body_size 256m;|g" "$NGINX_CONF" 2>/dev/null || true

# keepalive_timeout -> 65s
sed -i "s|keepalive_timeout[^;]*;|keepalive_timeout 65;|g" "$NGINX_CONF" 2>/dev/null || true

# keepalive_requests -> 1000
if grep -q "keepalive_requests" "$NGINX_CONF" 2>/dev/null; then
    sed -i "s|keepalive_requests[^;]*;|keepalive_requests 1000;|g" "$NGINX_CONF" 2>/dev/null || true
fi

# server_tokens off
sed -i "s|server_tokens[^;]*;|server_tokens off;|g" "$NGINX_CONF" 2>/dev/null || true

# gzip_comp_level -> 6
sed -i "s|gzip_comp_level[^;]*;|gzip_comp_level 6;|g" "$NGINX_CONF" 2>/dev/null || true

# tcp_nopush on
sed -i "s|tcp_nopush[^;]*;|tcp_nopush on;|g" "$NGINX_CONF" 2>/dev/null || true

# tcp_nodelay on
sed -i "s|tcp_nodelay[^;]*;|tcp_nodelay on;|g" "$NGINX_CONF" 2>/dev/null || true

# fastcgi_cache_path - a??adir si HestiaCP no lo define
# Necesario para que las reglas de cache en los vhosts funcionen
if ! grep -q "fastcgi_cache_path" "$NGINX_CONF" 2>/dev/null; then
    # Insertar antes del primer include dentro del bloque http{}
    sed -i "/include \/etc\/nginx\/conf\.d/i\    fastcgi_cache_path /dev/shm/nginx_cache levels=1:2 keys_zone=microcache:100m max_size=1g inactive=60m use_temp_path=off;"         "$NGINX_CONF" 2>/dev/null || true
    sed -i "/include \/etc\/nginx\/conf\.d/i\    fastcgi_cache_key "\$scheme\$request_method\$host\$request_uri";"         "$NGINX_CONF" 2>/dev/null || true
    sed -i "/include \/etc\/nginx\/conf\.d/i\    fastcgi_cache_use_stale error timeout invalid_header http_500;"         "$NGINX_CONF" 2>/dev/null || true
    sed -i "/include \/etc\/nginx\/conf\.d/i\    fastcgi_ignore_headers Cache-Control Expires Set-Cookie;"         "$NGINX_CONF" 2>/dev/null || true
    log "FastCGI cache path anadido a nginx.conf"
else
    log "FastCGI cache path ya definido en nginx.conf"
fi

# open_file_cache - cachea descriptores en RAM
if ! grep -q "open_file_cache" "$NGINX_CONF" 2>/dev/null; then
    sed -i "/include \/etc\/nginx\/conf\.d/i\    open_file_cache max=200000 inactive=20s;" "$NGINX_CONF" 2>/dev/null || true
    sed -i "/include \/etc\/nginx\/conf\.d/i\    open_file_cache_valid 30s;" "$NGINX_CONF" 2>/dev/null || true
    sed -i "/include \/etc\/nginx\/conf\.d/i\    open_file_cache_min_uses 2;" "$NGINX_CONF" 2>/dev/null || true
    sed -i "/include \/etc\/nginx\/conf\.d/i\    open_file_cache_errors on;" "$NGINX_CONF" 2>/dev/null || true
    log "open_file_cache anadido a nginx.conf"
else
    sed -i "s|open_file_cache max=[^;]*;|open_file_cache max=200000 inactive=20s;|g" "$NGINX_CONF" 2>/dev/null || true
    log "open_file_cache optimizado en nginx.conf"
fi

# client_body_buffer_size y large_client_header_buffers
# Solo a??adir si no existen
if ! grep -q "client_body_buffer_size" "$NGINX_CONF" 2>/dev/null; then
    sed -i "/client_max_body_size/a\    client_body_buffer_size 128k;" "$NGINX_CONF" 2>/dev/null || true
fi
if ! grep -q "large_client_header_buffers" "$NGINX_CONF" 2>/dev/null; then
    sed -i "/client_body_buffer_size/a\    large_client_header_buffers 4 16k;" "$NGINX_CONF" 2>/dev/null || true
fi

# Proxy buffers para backend Apache
if ! grep -q "proxy_buffer_size" "$NGINX_CONF" 2>/dev/null; then
    sed -i "/include \/etc\/nginx\/conf\.d/i\    proxy_buffer_size 128k;" "$NGINX_CONF" 2>/dev/null || true
    sed -i "/include \/etc\/nginx\/conf\.d/i\    proxy_buffers 4 256k;" "$NGINX_CONF" 2>/dev/null || true
    sed -i "/include \/etc\/nginx\/conf\.d/i\    proxy_busy_buffers_size 256k;" "$NGINX_CONF" 2>/dev/null || true
fi

# Timeouts adicionales
if ! grep -q "client_body_timeout" "$NGINX_CONF" 2>/dev/null; then
    sed -i "/include \/etc\/nginx\/conf\.d/i\    client_body_timeout 30s;" "$NGINX_CONF" 2>/dev/null || true
    sed -i "/include \/etc\/nginx\/conf\.d/i\    client_header_timeout 30s;" "$NGINX_CONF" 2>/dev/null || true
    sed -i "/include \/etc\/nginx\/conf\.d/i\    send_timeout 30s;" "$NGINX_CONF" 2>/dev/null || true
fi

# Hash sizes
if ! grep -q "types_hash_max_size" "$NGINX_CONF" 2>/dev/null; then
    sed -i "/include \/etc\/nginx\/conf\.d/i\    types_hash_max_size 2048;" "$NGINX_CONF" 2>/dev/null || true
fi
if ! grep -q "server_names_hash_bucket_size" "$NGINX_CONF" 2>/dev/null; then
    sed -i "/include \/etc\/nginx\/conf\.d/i\    server_names_hash_bucket_size 64;" "$NGINX_CONF" 2>/dev/null || true
fi

log "Nginx optimizado para maximo rendimiento"

# ---------------------------------------------
#  PASO 6: OPTIMIZACION APACHE (MOTOR WEB)
# ---------------------------------------------
header "PASO 6: Optimizando Apache como motor web"

cat > /etc/apache2/conf-available/performance.conf << 'APACHEEOF'
Timeout 300

<IfModule mpm_event_module>
    StartServers             2
    MinSpareThreads         25
    MaxSpareThreads         75
    ThreadLimit             64
    ThreadsPerChild         25
    ServerLimit            300
    StartServers           4
    MaxRequestWorkers      300
    ThreadsPerChild        25
    MinSpareThreads        25
    MaxSpareThreads        75
    MaxConnectionsPerChild 10000
</IfModule>

FileETag None
Header unset ETag
KeepAlive On
    KeepAliveTimeout 5
    MaxKeepAliveRequests 100
ServerTokens Prod
ServerSignature Off

<IfModule mod_deflate.c>
    AddOutputFilterByType DEFLATE text/html text/plain text/xml
    AddOutputFilterByType DEFLATE text/css text/javascript
    AddOutputFilterByType DEFLATE application/javascript application/json
    BrowserMatch ^Mozilla/4 gzip-only-text/html
    BrowserMatch \bMSIE !no-gzip !gzip-only-text/html
</IfModule>

<IfModule mod_expires.c>
    ExpiresActive On
    ExpiresByType image/jpeg "access plus 1 year"
    ExpiresByType image/png "access plus 1 year"
    ExpiresByType image/webp "access plus 1 year"
    ExpiresByType image/svg+xml "access plus 1 year"
    ExpiresByType text/css "access plus 1 month"
    ExpiresByType application/javascript "access plus 1 month"
    ExpiresByType font/woff2 "access plus 1 year"
</IfModule>
APACHEEOF

a2enconf performance 2>/dev/null || true
a2enmod deflate expires headers rewrite 2>/dev/null || true
log "Apache optimizado como backend"

# ---------------------------------------------
#  PASO 7: PHP - VERSIONES Y OPTIMIZACION
# ---------------------------------------------
header "PASO 7: Registrando versiones PHP en QemuCP y optimizando"

# Eliminar versiones PHP obsoletas y sin soporte instaladas por MultiPHP
# PHP 5.6, 7.0, 7.1 estan EOL y son un riesgo de seguridad.
# Si ALLOW_LEGACY_PHP=yes, NO se eliminan (cliente las necesita para webs antiguas).
if [ "$ALLOW_LEGACY_PHP" != "yes" ]; then
    PHP_OBSOLETE=("5.6" "7.0" "7.1")
    for VER in "${PHP_OBSOLETE[@]}"; do
        if [[ -f "/usr/bin/php${VER}" ]] || [[ -d "/etc/php/${VER}" ]]; then
            $HESTIA/bin/v-delete-web-php "$VER" 2>/dev/null || true
            apt-get purge -y -qq "php${VER}*" 2>/dev/null || true
            log "PHP $VER (EOL) eliminado por seguridad"
        fi
    done
else
    warn "ALLOW_LEGACY_PHP=yes: PHP 5.6/7.0/7.1 conservadas (bajo tu responsabilidad)"
fi

# Confirmar versiones disponibles en el panel
PHP_EXTRA_VERSIONS=("7.2" "7.3" "7.4" "8.0" "8.1" "8.2" "8.3" "8.4" "8.5")
for VER in "${PHP_EXTRA_VERSIONS[@]}"; do
    $HESTIA/bin/v-add-web-php "$VER" 2>/dev/null || true
    log "PHP $VER disponible en el panel"
done

# Instalar extensiones adicionales para todas las versiones disponibles
apt-get update -qq
for VER in "${PHP_VERSIONS[@]}"; do
    # Extensiones ESENCIALES (CMS/WordPress las necesitan) + optimizacion
    # mysql=mysqli (WordPress/PrestaShop), gd (imagenes), curl, mbstring, xml, zip, intl, bcmath, soap
    ESSENTIAL_EXTENSIONS="mysql gd curl mbstring xml zip intl bcmath soap"
    EXTRA_EXTENSIONS="imagick redis apcu mcrypt"
    for EXT in $ESSENTIAL_EXTENSIONS $EXTRA_EXTENSIONS; do
        apt-get install -y -qq "php${VER}-${EXT}" 2>/dev/null || true
    done
    log "Extensiones PHP $VER: mysql, gd, curl, mbstring, xml, zip, intl, bcmath, soap, imagick, redis, apcu, mcrypt"
done

# ------ Calcular workers segun RAM ------------------------------------------------------------------------------------------------------------------------------------------
RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
PHP_MAX_CHILDREN=$(( RAM_MB / 50 ))
[[ $PHP_MAX_CHILDREN -lt 4 ]] && PHP_MAX_CHILDREN=4
PHP_START_SERVERS=$(( PHP_MAX_CHILDREN / 4 ))
[[ $PHP_START_SERVERS -lt 2 ]] && PHP_START_SERVERS=2
PHP_MIN_SPARE=$PHP_START_SERVERS
PHP_MAX_SPARE=$(( PHP_MAX_CHILDREN / 2 ))
[[ $PHP_MAX_SPARE -lt 4 ]] && PHP_MAX_SPARE=4

# ------ Optimizar templates PHP-FPM de HestiaCP ---------------------------------------------------------------------------------------------------
# HestiaCP genera los pools PHP-FPM desde sus templates cuando crea dominios.
# Modificamos los templates para que TODOS los sitios hereden las optimizaciones.
HESTIA_PHP_TPL="$HESTIA/data/templates/web/php-fpm"
# Los backups van a un directorio SEPARADO, NO dentro del dir de templates.
# Si se guardan como *.tpl.bak junto a los .tpl, v-list-web-templates-backend
# los cuenta como versiones PHP instaladas (aparecen versiones fantasma).
TPL_BACKUP_DIR="$HESTIA/data/templates/web/php-fpm-backups"
mkdir -p "$TPL_BACKUP_DIR"

for TPL_FILE in "$HESTIA_PHP_TPL"/*.tpl; do
    [[ -f "$TPL_FILE" ]] || continue
cp "$TPL_FILE" "$TPL_BACKUP_DIR/$(basename "$TPL_FILE").bak" 2>/dev/null || true

    # Insertar optimizaciones si no estan ya.
    # La llave es la linea de comentario del bloque. Antes era
    # "memory_limit = 512M", que NUNCA coincidia con su propio bloque (lo
    # escrito es "memory_limit] = 512M", con corchete): cada vez que se
    # relanzaba el instalador se anadia otro bloque con otra linea
    # session.save_path a todas las plantillas.
    if ! grep -q "^; -- QemuCP: Optimizaciones de rendimiento --" "$TPL_FILE" 2>/dev/null; then
        # La plantilla de HestiaCP YA trae session.save_path apuntando a
        # /home/%user%/tmp. Si se deja esa linea y se anade la de Redis,
        # el pool acaba con DOS session.save_path y PHP toma el equivocado:
        # las webs con sesiones fallan con "Redis connection not available
        # ... Failed to read session data: redis (path: /home/USER/tmp)".
        # Visto en produccion en PrestaShop, Joomla y Moodle.
        sed -i '/^php_admin_value\[session.save_path\] = \/home\//d' "$TPL_FILE" 2>/dev/null || true

        # Anadir valores optimizados al final del template
        cat >> "$TPL_FILE" << 'TPLEOF'

; -- QemuCP: Optimizaciones de rendimiento --
; Memoria y uploads
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 256M
php_admin_value[post_max_size] = 256M
php_admin_value[max_file_uploads] = 100
; Ejecucion
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_time] = 300
php_admin_value[max_input_vars] = 10000
; Seguridad
php_flag[display_errors] = off
php_admin_flag[log_errors] = on
; Sesiones via Redis
php_admin_value[session.save_handler] = redis
php_admin_value[session.save_path] = "tcp://127.0.0.1:6379?timeout=1&prefix=SESS_&database=1"
php_admin_value[session.gc_maxlifetime] = 1440
php_admin_value[session.cookie_httponly] = 1
php_admin_value[session.cookie_secure] = 1
; SOAP (PrestaShop)
php_value[soap.wsdl_cache_enabled] = 1
php_value[soap.wsdl_cache_ttl] = 86400
; OPcache
php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 256
php_admin_value[opcache.interned_strings_buffer] = 32
php_admin_value[opcache.max_accelerated_files] = 30000
php_admin_value[opcache.validate_timestamps] = 1
php_admin_value[opcache.revalidate_freq] = 60
php_admin_value[opcache.save_comments] = 1
TPLEOF
        log "Template PHP-FPM optimizado: $(basename $TPL_FILE)"
    fi
done

# ------ Optimizar PHP via ficheros .ini dedicados en conf.d/ ---------------------------------------------------------
# Usamos /etc/php/VERSION/fpm/conf.d/ y cli/conf.d/ que es la forma correcta
# en Ubuntu/Debian. HestiaCP no sobreescribe estos ficheros.
# Tambien actualizamos php.ini para los valores basicos.
for PHP_VERSION in "${PHP_VERSIONS[@]}"; do
    [[ -d "/etc/php/${PHP_VERSION}" ]] || continue

    # -- php.ini: valores basicos que HestiaCP respeta
    for PHP_INI in "/etc/php/${PHP_VERSION}/fpm/php.ini" "/etc/php/${PHP_VERSION}/cli/php.ini"; do
        [[ -f "$PHP_INI" ]] || continue
        sed -i \
            -e "s/^memory_limit.*/memory_limit = 512M/" \
            -e "s/^upload_max_filesize.*/upload_max_filesize = 256M/" \
            -e "s/^post_max_size.*/post_max_size = 256M/" \
            -e "s/^max_execution_time.*/max_execution_time = 300/" \
            -e "s/^max_input_time.*/max_input_time = 300/" \
            -e "s/^;*max_input_vars.*/max_input_vars = 10000/" \
            -e "s/^expose_php.*/expose_php = Off/" \
            -e "s/^allow_url_fopen.*/allow_url_fopen = On/" \
            -e "s/^;*realpath_cache_size.*/realpath_cache_size = 4096k/" \
            -e "s/^;*realpath_cache_ttl.*/realpath_cache_ttl = 600/" \
            "$PHP_INI" 2>/dev/null || true
    done

    # -- Fichero dedicado para OPcache (fpm + cli)
    for CONF_DIR in "/etc/php/${PHP_VERSION}/fpm/conf.d" "/etc/php/${PHP_VERSION}/cli/conf.d"; do
        [[ -d "$CONF_DIR" ]] || continue

        # OPcache
        cat > "$CONF_DIR/99-qemucp-opcache.ini" << 'OPCEOF'
[opcache]
opcache.enable=1
opcache.enable_cli=0
opcache.memory_consumption=256
opcache.interned_strings_buffer=32
opcache.max_accelerated_files=30000
opcache.max_wasted_percentage=10
opcache.validate_timestamps=1
opcache.revalidate_freq=60
opcache.fast_shutdown=1
opcache.save_comments=1
OPCEOF

        # OPcache JIT solo para PHP 8+
        PHP_MAJOR="${PHP_VERSION%%.*}"
        if [[ "$PHP_MAJOR" -ge 8 ]]; then
            cat >> "$CONF_DIR/99-qemucp-opcache.ini" << 'JITEOF'
opcache.jit=tracing
opcache.jit_buffer_size=64M
opcache.huge_code_pages=1
JITEOF
        fi

        # APCu - fichero dedicado con seccion correcta
        cat > "$CONF_DIR/99-qemucp-apcu.ini" << 'APCEOF'
[apcu]
apc.enabled=1
apc.shm_size=128M
apc.ttl=7200
apc.enable_cli=1
apc.slam_defense=1
apc.coredump_unmap=0
APCEOF

    done
    log "PHP $PHP_VERSION: OPcache + APCu configurados via conf.d"
done

mkdir -p /var/lib/php/sessions /var/lib/php/wsdlcache
chown -R www-data:www-data /var/lib/php/ 2>/dev/null || true
chmod 1733 /var/lib/php/sessions 2>/dev/null || true

# ---------------------------------------------
#  PASO 7B: REDIS - CACHE DE OBJETOS EN RAM
# ---------------------------------------------
header "PASO 7B: Instalando y configurando Redis"

apt-get install -y -qq redis-server 2>/dev/null || true

# Configurar Redis optimizado para cache de objetos web
cp /etc/redis/redis.conf /etc/redis/redis.conf.bak 2>/dev/null || true

# maxmemory: 20% de la RAM para Redis
REDIS_MEM=$(( RAM_MB / 5 ))
[[ $REDIS_MEM -lt 64 ]] && REDIS_MEM=64

cat > /etc/redis/redis.conf << REDISEOF
# QemuCP - Redis optimizado para cache de objetos
bind 127.0.0.1
port 6379
protected-mode yes

# Memoria maxima y politica de desalojo (LRU = elimina los menos usados)
maxmemory ${REDIS_MEM}mb
maxmemory-policy allkeys-lru

# Persistencia desactivada (solo cache, no necesitamos guardar datos en disco)
save ""
appendonly no

# Rendimiento
tcp-backlog 511
timeout 300
tcp-keepalive 60
databases 16

# Limite de conexiones
maxclients 1000

# Logs
loglevel notice
logfile /var/log/redis/redis-server.log
lazyfree-lazy-eviction yes
lazyfree-lazy-expire yes
lazyfree-lazy-server-del yes
activerehashing yes
hz 20
REDISEOF

systemctl enable redis-server
log "Redis instalado (${REDIS_MEM}MB RAM * LRU * solo localhost)"

# Instalar extension PHP redis para todas las versiones
for VER in "${PHP_VERSIONS[@]}"; do
    apt-get install -y -qq php${VER}-redis 2>/dev/null && \
        log "PHP $VER redis extension instalada" || \
        warn "PHP $VER redis extension no disponible"
done

log "Redis listo ? activalo en WordPress con: WP Redis o W3 Total Cache"
log "Redis listo ? activalo en PrestaShop con: modulo Redis Cache"

# ---------------------------------------------
#  PASO 7C: NGINX FASTCGI CACHE ACTIVO EN VHOSTS
# ---------------------------------------------
header "PASO 7C: Activando FastCGI cache en vhosts Nginx"

# Crear snippet de FastCGI cache reutilizable para vhosts
mkdir -p /etc/nginx/snippets

cat > /etc/nginx/snippets/fastcgi-cache.conf << 'EOF'
# QemuCP - FastCGI Cache snippet
# Incluir dentro del bloque location ~ \.php$ de cada vhost

# Activar cache
fastcgi_cache microcache;
fastcgi_cache_valid 200 301 302 10m;
fastcgi_cache_valid 404 1m;
fastcgi_cache_min_uses 1;
fastcgi_cache_lock on;
fastcgi_cache_lock_timeout 5s;

# No cachear si el usuario esta logado o hay cookie de sesion activa
fastcgi_cache_bypass $cookie_PHPSESSID $cookie_wordpress_logged_in $cookie_woocommerce_cart $cookie_prestashop;
fastcgi_no_cache $cookie_PHPSESSID $cookie_wordpress_logged_in $cookie_woocommerce_cart $cookie_prestashop;

# Header para saber si se sirvio desde cache (HIT/MISS/BYPASS)
add_header X-Cache-Status $upstream_cache_status always;
EOF
log "Snippet FastCGI cache creado: /etc/nginx/snippets/fastcgi-cache.conf"

# Crear snippet de exclusiones de cache (URLs que nunca se cachean)
cat > /etc/nginx/snippets/fastcgi-cache-skip.conf << 'EOF'
# QemuCP - URLs que nunca se cachean
# Incluir dentro del bloque server{} antes de los location

set $skip_cache 0;

# WordPress: admin, login, WooCommerce
if ($request_uri ~* "(/wp-admin/|/wp-login.php|/cart/|/checkout/|/my-account/)") {
    set $skip_cache 1;
}
# PrestaShop: admin, carrito, cuenta
if ($request_uri ~* "(/admin|/panier|/commande|/mon-compte|/carrinho|/pedido|/carrito|/order)") {
    set $skip_cache 1;
}
# Peticiones POST nunca se cachean
if ($request_method = POST) {
    set $skip_cache 1;
}
# Query strings dinamicas
if ($query_string != "") {
    set $skip_cache 1;
}
EOF
log "Snippet de exclusiones de cache creado"

# Inyectar snippets en los templates de vhost de HestiaCP
# para que todos los sitios nuevos los hereden
NGINX_TPL_DIR="$HESTIA/data/templates/web/nginx"
for TPL in "$NGINX_TPL_DIR"/*.tpl "$NGINX_TPL_DIR"/*.stpl; do
    [[ -f "$TPL" ]] || continue
    if ! grep -q "fastcgi-cache-skip" "$TPL" 2>/dev/null; then
        sed -i '/^server[[:space:]]*{/a\    include /etc/nginx/snippets/fastcgi-cache-skip.conf;' "$TPL"
    fi
done
log "FastCGI cache integrado en templates de vhost"

# ---------------------------------------------
#  PASO 7D: BROTLI - COMPRESION AVANZADA
# ---------------------------------------------
header "PASO 7D: Instalando modulo Brotli para Nginx"

# Compilar modulo Brotli dinamico (OPCIONAL - no aborta si falla)
BROTLI_MODULE="no"
NGINX_VER_BROTLI=$(nginx -v 2>&1 | grep -oP '[\d.]+$')
apt-get install -y -qq libbrotli-dev 2>/dev/null || true

if rm -rf /root/tmp_brotli && mkdir -p /root/tmp_brotli && cd /root/tmp_brotli \
   && wget -q --timeout=30 "http://nginx.org/download/nginx-${NGINX_VER_BROTLI}.tar.gz" 2>/dev/null \
   && tar -xzf "nginx-${NGINX_VER_BROTLI}.tar.gz" 2>/dev/null \
   && git clone --depth 1 --recurse-submodules https://github.com/google/ngx_brotli.git 2>/dev/null; then

    CONFARGS_BROTLI=$(nginx -V 2>&1 | grep "configure arguments:" | sed 's/configure arguments: //')
    if cd "/root/tmp_brotli/nginx-${NGINX_VER_BROTLI}" 2>/dev/null \
       && eval "./configure --with-compat ${CONFARGS_BROTLI} --add-dynamic-module=/root/tmp_brotli/ngx_brotli" >/dev/null 2>&1 \
       && make -j$(nproc) modules >/dev/null 2>&1 \
       && cp objs/ngx_http_brotli_filter_module.so /etc/nginx/modules/ 2>/dev/null \
       && cp objs/ngx_http_brotli_static_module.so /etc/nginx/modules/ 2>/dev/null; then
        chmod 644 /etc/nginx/modules/ngx_http_brotli_*.so 2>/dev/null || true
        BROTLI_MODULE="yes"
        log "Modulos Brotli compilados e instalados"
    else
        warn "No se pudo compilar Brotli - se instalara sin compresion Brotli"
    fi
else
    warn "No se pudieron obtener fuentes para Brotli - se omite"
fi
rm -rf /root/tmp_brotli 2>/dev/null || true

# Anadir load_module de Brotli SOLO si se compilo
if [ "${BROTLI_MODULE:-no}" = "yes" ] && [ -f /etc/nginx/modules/ngx_http_brotli_filter_module.so ]; then
    if grep -q "ngx_http_geoip2_module" /etc/nginx/nginx.conf 2>/dev/null; then
        sed -i 's|load_module modules/ngx_http_geoip2_module.so;|load_module modules/ngx_http_geoip2_module.so;\nload_module modules/ngx_http_brotli_filter_module.so;\nload_module modules/ngx_http_brotli_static_module.so;|' \
            /etc/nginx/nginx.conf
    else
        # No hay geoip2 - anadir brotli al inicio del fichero
        { echo "load_module modules/ngx_http_brotli_filter_module.so;"; echo "load_module modules/ngx_http_brotli_static_module.so;"; cat /etc/nginx/nginx.conf; } > /tmp/nginx_brotli_tmp.conf && \
        mv /tmp/nginx_brotli_tmp.conf /etc/nginx/nginx.conf
    fi
    log "Brotli load_module anadido"
else
    warn "Brotli no compilado - se omite load_module"
fi

# Anadir configuracion Brotli en el bloque http{} SOLO si el modulo se cargo
if [ "${BROTLI_MODULE:-no}" = "yes" ]; then
    sed -i '/gzip_types/a\
\
    # Brotli (mejor compresion que Gzip, ~15-20% mas)\
    brotli on;\
    brotli_comp_level 6;\
    brotli_static on;\
    brotli_min_length 1000;\
    brotli_types\
        text/plain text/css text/xml text/javascript\
        application/json application/javascript application/xml\
        application/rss+xml application/atom+xml\
        image/svg+xml font/ttf font/otf font/woff font/woff2;' \
        /etc/nginx/nginx.conf
    log "Brotli activado en Nginx (nivel 6)"
else
    warn "Brotli no disponible - nginx usara solo Gzip"
fi

# ---------------------------------------------
#  PASO 8: OPTIMIZACION MARIADB 10.11
# ---------------------------------------------
header "PASO 8: Optimizando MariaDB"

# Buffer pool = 50% de la RAM (si RAM_MB es 0 por algun fallo, minimo 256M)
[[ -z "$RAM_MB" || "$RAM_MB" -lt 512 ]] && RAM_MB=512
INNODB_BUFFER=$(( RAM_MB / 2 ))
[[ $INNODB_BUFFER -lt 128 ]] && INNODB_BUFFER=128
# innodb_buffer_pool_instances ya no se usa: MariaDB la elimino en la 10.6
# (MDEV-23397) y desde entonces no hace nada. El fork instala la 11.8.

cat > /etc/mysql/mariadb.conf.d/99-qemucp-optimize.cnf << MYSQLEOF
# QemuCP - MariaDB optimizado para maxima compatibilidad
# Compatible con: WordPress, PrestaShop, Magento, Joomla, Laravel, etc.
[mysqld]

# -- Conexiones ----------------------------------------------------------------
max_connections          = 300
max_allowed_packet       = 256M
wait_timeout             = 300
interactive_timeout      = 300
connect_timeout          = 10
max_connect_errors       = 10000

# -- Charset y collation (maxima compatibilidad Unicode) -----------------------
# utf8mb4 soporta emojis y todos los caracteres Unicode (a diferencia de utf8)
character_set_server     = utf8mb4
collation_server         = utf8mb4_unicode_ci
character_set_filesystem = utf8mb4
init_connect             = 'SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci'
skip-character-set-client-handshake

# -- Modo SQL: compatible con la mayoria de CMSs y frameworks -----------------
# STRICT_TRANS_TABLES: evita datos silenciosos incorrectos
# NO_ZERO_IN_DATE / NO_ZERO_DATE: compatibilidad con WP y PS
# ERROR_FOR_DIVISION_BY_ZERO: evita divisiones silenciosas
# NO_AUTO_CREATE_USER: seguridad
# NO_ENGINE_SUBSTITUTION: no cambia el motor de tabla silenciosamente
sql_mode                 = "STRICT_TRANS_TABLES,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION"

# -- Motor InnoDB (predeterminado para todo) -----------------------------------
default_storage_engine   = InnoDB
innodb_buffer_pool_size  = ${INNODB_BUFFER}M
innodb_log_file_size     = 256M
innodb_log_buffer_size   = 64M
innodb_flush_log_at_trx_commit = 2        # 0=max rendimiento, 1=max seguridad, 2=balance
innodb_flush_method      = O_DIRECT       # Evita doble cache con el SO
innodb_file_per_table    = 1              # Un fichero .ibd por tabla (mas facil gestion)
innodb_read_io_threads   = 4
innodb_write_io_threads  = 4
innodb_io_capacity       = 2000
innodb_io_capacity_max   = 4000
innodb_open_files        = 4000
innodb_stats_on_metadata = 0              # Evita re-analisis automaticos que ralentizan
innodb_autoinc_lock_mode = 2              # Mayor concurrencia en inserciones masivas (PrestaShop imports)

# -- Tablas y ficheros ---------------------------------------------------------
open_files_limit         = 65535
table_open_cache         = 4000
table_definition_cache   = 2000
table_open_cache_instances = 8
table_definition_cache   = 4000
thread_cache_size        = 16
thread_stack             = 256K

# -- Buffers de memoria --------------------------------------------------------
tmp_table_size           = 128M
max_heap_table_size      = 128M           # Tablas temporales en RAM antes de volcar a disco
sort_buffer_size         = 4M
join_buffer_size         = 4M
read_buffer_size         = 2M
read_rnd_buffer_size     = 4M
bulk_insert_buffer_size  = 64M            # Acelera importaciones masivas (CSV PrestaShop)
key_buffer_size          = 32M            # Para indices MyISAM (algunas tablas WP)

# -- Query cache ---------------------------------------------------------------
query_cache_type         = 0
query_cache_size         = 0
query_cache_limit        = 4M
query_cache_min_res_unit = 2k

# -- Busquedas de texto completo (FULLTEXT) ------------------------------------
# WordPress usa FULLTEXT para busquedas, PrestaShop tambien
ft_min_word_len          = 3              # Indexar palabras de 3+ caracteres (defecto 4)
innodb_ft_min_token_size = 3              # Igual para InnoDB FULLTEXT

# -- Compatibilidad con GROUP BY sin agregar (WP y algunos plugins lo usan) ---
# ONLY_FULL_GROUP_BY esta desactivado intencionalmente para maxima compatibilidad

# -- Logs ----------------------------------------------------------------------
slow_query_log           = 1
slow_query_log_file      = /var/log/mysql/slow.log
long_query_time          = 2
log_queries_not_using_indexes = 0         # Activar solo para debug (genera mucho log)

# -- Seguridad -----------------------------------------------------------------
local_infile             = 0              # Desactivar LOAD DATA LOCAL (seguridad)
symbolic_links           = 0              # Desactivar symlinks en tablas

# -- Acceso remoto -------------------------------------------------------------
# bind-address = 0.0.0.0 permite conexiones desde cualquier IP
# Protegido por fail2ban (ban tras 3 intentos fallidos) y el firewall de HestiaCP
bind-address             = 0.0.0.0

# -- Timeouts y keepalive ------------------------------------------------------
net_read_timeout         = 30
net_write_timeout        = 30
lock_wait_timeout        = 120

# -- Performance schema desactivado (ahorra RAM en servidores pequenos) --------
performance_schema       = OFF

[client]
default-character-set    = utf8mb4

[mysql]
default-character-set    = utf8mb4

[mysqldump]
max_allowed_packet       = 256M
default-character-set    = utf8mb4
MYSQLEOF

# Que MariaDB lea de verdad este fichero. HestiaCP instala my-small.cnf o
# my-medium.cnf (con !includedir de mariadb.conf.d) o, con mas de ~3,9 GB de
# RAM, my-large.cnf, que NO lo incluye: en los servidores grandes todo lo de
# arriba se ignoraba sin avisar. Se incluye SOLO este fichero, para no
# arrastrar el resto de mariadb.conf.d a una configuracion que no lo espera.
QEMUCP_MYCNF="/etc/mysql/my.cnf"
if [[ -f "$QEMUCP_MYCNF" ]] \
   && ! grep -q "^!includedir /etc/mysql/mariadb.conf.d" "$QEMUCP_MYCNF" \
   && ! grep -q "^!include /etc/mysql/mariadb.conf.d/99-qemucp-optimize.cnf" "$QEMUCP_MYCNF"; then
    printf '\n!include /etc/mysql/mariadb.conf.d/99-qemucp-optimize.cnf\n' >> "$QEMUCP_MYCNF"
    log "my.cnf no leia mariadb.conf.d (servidor grande): incluido 99-qemucp-optimize.cnf"
fi
log "MariaDB optimizado (InnoDB ${INNODB_BUFFER}MB * utf8mb4 * modo SQL compatible)"


# ---------------------------------------------
#  PASO 9: SSL AUTOMATICO (LET'S ENCRYPT)
# ---------------------------------------------
header "PASO 9: Configurando SSL automatico"

if command -v certbot &>/dev/null; then
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 * * * /usr/bin/certbot renew --quiet --post-hook 'systemctl reload nginx apache2' 2>/dev/null") | crontab -
        log "Renovacion automatica SSL: diaria 3:00 AM"
    fi
fi

if [[ -f "$HESTIA/bin/v-add-letsencrypt-host" ]]; then
    "$HESTIA/bin/v-add-letsencrypt-host" 2>/dev/null && \
        log "SSL Let's Encrypt activado para el panel" || \
        warn "SSL panel: apunta el DNS primero y ejecuta: v-add-letsencrypt-host"
fi

# ---------------------------------------------
#  PASO 10: SEGURIDAD (FAIL2BAN + FIREWALL)
# ---------------------------------------------
header "PASO 10: Configurando seguridad"

cat > /etc/fail2ban/jail.local << 'F2BEOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = ssh
maxretry = 5
bantime = 7200

[nginx-http-auth]
enabled = true
filter  = nginx-http-auth
port    = http,https
logpath = /var/log/nginx/error.log

[nginx-botsearch]
enabled  = true
filter   = nginx-botsearch
port     = http,https
logpath  = /var/log/nginx/access.log
maxretry = 2

[nginx-limit-req]
enabled = true
filter  = nginx-limit-req
port    = http,https
logpath = /var/log/nginx/error.log

[hestia]
enabled  = true
port     = 8083
filter   = hestia
maxretry = 5

[mysql-auth]
enabled  = true
port     = 3306
filter   = mysqld-auth
logpath  = /var/log/mysql/error.log
maxretry = 3
bantime  = 86400

[nginx-badbots]
enabled  = true
filter   = nginx-badbots
port     = http,https
logpath  = /var/log/nginx/access.log
maxretry = 3
bantime  = 3600
findtime = 3600

[nginx-444]
enabled  = true
filter   = nginx-444
port     = http,https
logpath  = /var/log/nginx/access_all.log
maxretry = 10
bantime  = 3600
findtime = 3600

F2BEOF

log "Fail2ban configurado"

# Filtro para bots conocidos por User-Agent (acceso.log de Nginx)
cat > /etc/fail2ban/filter.d/nginx-badbots.conf << 'FILTEREOF'
[Definition]
failregex = ^<HOST> .* "(GET|POST|HEAD).*" \d+ .* "(SemrushBot|AhrefsBot|GPTBot|OpenAI|TikTokSpider|Bytespider|SERankingBacklinksBot|MJ12bot|DotBot|BLEXBot|PetalBot|YandexBot).*"$
ignoreregex =
FILTEREOF
log "Filtro nginx-badbots creado"

# Filtro para IPs que reciben 444 repetidamente (conexion cerrada por bot/GeoIP)
cat > /etc/fail2ban/filter.d/nginx-444.conf << 'FILTEREOF'
[Definition]
# Detecta IPs que reciben multiples 444 (connection closed - bots/paises bloqueados)
failregex = ^<HOST> .* "(GET|POST|HEAD|OPTIONS|CONNECT).*" 444
ignoreregex =
FILTEREOF
log "Filtro nginx-444 creado"


SSHD="/etc/ssh/sshd_config"
cp "$SSHD" "$SSHD.bak" 2>/dev/null || true
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin yes/' "$SSHD"
sed -i 's/^#*MaxAuthTries.*/MaxAuthTries 6/' "$SSHD"
sed -i 's/^#*LoginGraceTime.*/LoginGraceTime 30/' "$SSHD"

# Parche necesario: nuestro bloque SSH sobreescribe lo que el instalador
# de HestiaCP configura en sshd_config. Hay que restaurar los valores
# que HestiaCP necesita para que el File Manager y SFTP funcionen.

# FIX #1: File Manager SFTP - Subsystem sftp internal-sftp
# El File Manager (FileGator) usa SFTP interno. CRITICO: la directiva
# 'Subsystem' debe ir FUERA de cualquier bloque 'Match' y solo puede
# aparecer UNA vez. En Ubuntu 22.04 el sshd es estricto y falla si hay
# un Subsystem dentro de un Match (rompe SSH = perdida de acceso).
# Estrategia robusta: eliminar TODAS las lineas Subsystem sftp existentes
# y reinsertar una sola, antes de cualquier bloque Match.
# 1. Eliminar todas las definiciones Subsystem sftp (por defecto y las nuestras)
sed -i '/^[[:space:]]*Subsystem[[:space:]]\+sftp/d' "$SSHD"
# 2. Insertar el Subsystem correcto ANTES del primer bloque Match (o al final si no hay)
if grep -q "^Match " "$SSHD" 2>/dev/null; then
    # Insertar justo antes de la primera linea "Match" (y antes de comentarios previos tipo "# Hestia SFTP")
    FIRST_MATCH_LINE=$(grep -n "^Match \|^# Hestia SFTP" "$SSHD" | head -1 | cut -d: -f1)
    if [ -n "$FIRST_MATCH_LINE" ]; then
        sed -i "${FIRST_MATCH_LINE}i Subsystem sftp internal-sftp\n" "$SSHD"
    else
        echo "Subsystem sftp internal-sftp" >> "$SSHD"
    fi
else
    echo "Subsystem sftp internal-sftp" >> "$SSHD"
fi
log "FIX #1: Subsystem sftp internal-sftp (fuera de Match, sin duplicados)"

# FIX #1B: crear /run/sshd (privilege separation dir).
# En /run (tmpfs) puede no existir tras la instalacion y sshd -t falla con
# "Missing privilege separation directory". Crearlo y asegurar que systemd
# lo recree en cada arranque.
mkdir -p /run/sshd && chmod 0755 /run/sshd
# Persistir via tmpfiles para que sobreviva reinicios
echo "d /run/sshd 0755 root root -" > /etc/tmpfiles.d/sshd.conf 2>/dev/null || true
log "FIX #1B: /run/sshd creado y persistido"

# FIX #2: PubkeyAuthentication requerida por el File Manager
# El File Manager autentica internamente con clave SSH publica.
# Sin esta directiva en yes el File Manager no puede conectar.
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD"
grep -q "^PubkeyAuthentication yes" "$SSHD" || echo "PubkeyAuthentication yes" >> "$SSHD"
log "FIX #2: PubkeyAuthentication yes verificado (File Manager)"

# FIX #3: SpamAssassin / spamd en Ubuntu 24.04
# En Ubuntu 24.04 el servicio se llama 'spamd' en lugar de 'spamassassin'.
# El instalador de HestiaCP 1.9.x ya lo gestiona correctamente durante la
# instalacion, pero el panel web puede intentar reiniciar 'spamassassin'
# y fallar. Creamos un alias de systemd de compatibilidad.
# Ref: https://github.com/hestiacp/hestiacp/issues/3931
if systemctl list-unit-files 2>/dev/null | grep -q "^spamd.service"; then
    if [[ ! -f /etc/systemd/system/spamassassin.service ]]; then
        ln -sf /lib/systemd/system/spamd.service \
            /etc/systemd/system/spamassassin.service 2>/dev/null || true
        systemctl daemon-reload 2>/dev/null || true
        log "FIX #3: Alias systemd spamassassin -> spamd creado"
    else
        log "FIX #3: Alias spamassassin ya existe, omitido"
    fi
fi

# Generar claves SSH para el usuario admin si no existen
# Necesarias para que el File Manager pueda autenticar via SFTP interno
if [[ ! -f /home/admin/.ssh/id_rsa ]]; then
    mkdir -p /home/admin/.ssh
    ssh-keygen -t rsa -b 4096 -f /home/admin/.ssh/id_rsa -N "" -q
    cat /home/admin/.ssh/id_rsa.pub >> /home/admin/.ssh/authorized_keys
    chmod 700 /home/admin/.ssh 2>/dev/null || true
    chmod 600 /home/admin/.ssh/authorized_keys 2>/dev/null || true
    chown -R admin:admin /home/admin/.ssh 2>/dev/null || true
    log "Claves SSH admin generadas para File Manager"
fi

# Registrar clave SFTP del admin en el panel
$HESTIA/bin/v-add-user-sftp-key admin 2>/dev/null && \
    log "Clave SFTP admin registrada correctamente" || \
    warn "Clave SFTP: ejecuta manualmente v-add-user-sftp-key admin si el File Manager falla"

# CRITICO: validar la config ANTES de reiniciar. Si sshd_config tiene un
# error, reiniciar dejaria el servidor SIN ACCESO SSH. Si falla, avisamos
# y NO reiniciamos (SSH sigue corriendo con la config anterior valida).
mkdir -p /run/sshd && chmod 0755 /run/sshd 2>/dev/null || true
if sshd -t 2>/tmp/sshd_test.log; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    log "SSH configurado y reiniciado (config valida)"
else
    warn "sshd -t fallo - NO se reinicia SSH para no perder acceso:"
    cat /tmp/sshd_test.log | sed 's/^/    /'
    warn "Revisa /etc/ssh/sshd_config. SSH sigue con la config anterior."
    # Intento de auto-reparacion: restaurar backup si existe
    if [ -f "$SSHD.bak" ] && sshd -t -f "$SSHD.bak" 2>/dev/null; then
        cp "$SSHD.bak" "$SSHD"
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        warn "sshd_config restaurado desde backup (config valida)"
    fi
fi

# FIX #4: FileGator / File Manager - PHP 8.3 compatibility
# SessionStorage no implementa migrate() requerido por SessionHandlerInterface en PHP 8.1+
# Causa: Fatal error al abrir el File Manager (/fm/)
FM_SESSION="$HESTIA/web/fm/backend/Services/Session/Adapters/SessionStorage.php"
if [ -f "$FM_SESSION" ] && ! grep -q "function migrate" "$FM_SESSION"; then
    cp "$FM_SESSION" "$FM_SESSION.bak" 2>/dev/null || true
    python3 << 'FMEOF'
with open("/usr/local/hestia/web/fm/backend/Services/Session/Adapters/SessionStorage.php") as f:
    content = f.read()
if "function migrate" not in content:
    method = """
    public function migrate($destroy = false, $lifetime = null): bool
    {
        if ($destroy) {
            $this->destroy(session_id());
        }
        return session_regenerate_id($destroy);
    }
"""
    last = content.rfind("}")
    content = content[:last] + method + content[last:]
    with open("/usr/local/hestia/web/fm/backend/Services/Session/Adapters/SessionStorage.php", "w") as f:
        f.write(content)
    print("OK")
FMEOF
    log "FIX #4: FileGator migrate() anadido (PHP 8.3 compatibility)"
else
    log "FIX #4: FileGator migrate() ya presente o fichero no encontrado"
fi

# FIX #6: File Manager - soporte tar.gz en descompresion
# Por defecto FileGator solo permite descomprimir .zip
# Parcheamos isArchive() en app.js para soportar .tar.gz, .tgz, .tar.bz2
FM_APPJS="$HESTIA/web/fm/dist/js/app.js"
if [ -f "$FM_APPJS" ]; then
    cp "$FM_APPJS" "$FM_APPJS.bak" 2>/dev/null || true
    python3 << 'JSEOF'
with open("/usr/local/hestia/web/fm/dist/js/app.js") as f:
    content = f.read()

old = 'isArchive(e){return"file"==e.type&&"zip"==e.name.split(".").pop()}'
new = 'isArchive(e){if("file"!=e.type)return false;var ext=e.name.split(".").pop().toLowerCase();var ext2=e.name.split(".").slice(-2).join(".").toLowerCase();return"zip"==ext||"tgz"==ext||"tar.gz"==ext2||"tar.bz2"==ext2}'

if old in content:
    content = content.replace(old, new)
    with open("/usr/local/hestia/web/fm/dist/js/app.js", "w") as f:
        f.write(content)
    print("OK")
else:
    print("SKIP - ya aplicado o version diferente")
JSEOF
    log "FIX #6: File Manager tar.gz support anadido"
else
    warn "FIX #6: app.js no encontrado - File Manager puede no estar instalado"
fi

# FIX #5: Sudoers - hestiaweb necesita chmod para el File Manager
# El File Manager ejecuta: sudo chmod o+x /home/USER/.ssh
# hestiaweb solo tiene permiso para /usr/local/hestia/bin/* por defecto
# Sin este fix aparece "Error desconocido" al abrir el File Manager
SUDOERS_FILE="/etc/sudoers.d/hestiaweb"
if ! grep -q "chmod" "$SUDOERS_FILE" 2>/dev/null; then
    echo "hestiaweb   ALL=NOPASSWD:/usr/bin/chmod o+x /home/*/.ssh" >> "$SUDOERS_FILE"
    echo "hestiaweb   ALL=NOPASSWD:/usr/bin/chmod 700 /home/*/.ssh" >> "$SUDOERS_FILE"
    log "FIX #5: Sudoers chmod anadido para File Manager"
else
    log "FIX #5: Sudoers chmod ya presente"
fi
cat > /etc/sysctl.d/99-qemucp-performance.conf << 'SYSCTLEOF'
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_fin_timeout = 10
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_tw_reuse = 1
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
fs.file-max = 2097152
SYSCTLEOF

# -e ignora claves que el kernel no tiene. Sin el, en un VPS con IPv6
# desactivado (no existe net.ipv6.*) sysctl devolvia error y, con set -e,
# la instalacion abortaba aqui en el PASO 10.
sysctl -e -p /etc/sysctl.d/99-qemucp-performance.conf > /dev/null 2>&1 \
    || warn "Algunos parametros de kernel no se aplicaron (normal en contenedores)"
log "Parametros de kernel optimizados"

# ---------------------------------------------
#  PASO 10B: CORRECCION FICHERO IP NGINX
# ---------------------------------------------
header "PASO 10B: Corrigiendo configuracion Nginx para IP directa"

# HestiaCP genera /etc/nginx/conf.d/$SERVER_IP.conf durante la instalacion
# Hay que:
# 1. Anadir phpmyadmin.inc en ambos bloques (80 y 443)
# 2. Eliminar el return 301 del bloque 443 (causa bucles con dominios SSL)

# Obtener IP publica del servidor
SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null ||             curl -s --max-time 5 api.ipify.org 2>/dev/null ||             hostname -I | awk '{print $1}')
IP_CONF="/etc/nginx/conf.d/${SERVER_IP}.conf"
if [ -f "$IP_CONF" ]; then
    cp "$IP_CONF" "$IP_CONF.bak"
    cat > "$IP_CONF" << IPCEOF
server {
    include /etc/nginx/conf.d/server-includes/main-rules.conf;
        listen ${SERVER_IP}:80 default_server;
        server_name _;
        access_log off;
        error_log /dev/null;
        include /etc/nginx/conf.d/phpmyadmin.inc;
        include /etc/nginx/conf.d/phppgadmin.inc;
        location / {
                proxy_pass http://${SERVER_IP}:8080;
        }
}
server {
    include /etc/nginx/conf.d/server-includes/main-rules.conf;
        listen ${SERVER_IP}:443 default_server ssl;
        server_name _;
        access_log off;
        error_log /dev/null;
        ssl_certificate     /usr/local/hestia/ssl/certificate.crt;
        ssl_certificate_key /usr/local/hestia/ssl/certificate.key;
        include /etc/nginx/conf.d/phpmyadmin.inc;
        include /etc/nginx/conf.d/phppgadmin.inc;
        location / {
                root /var/www/document_errors/;
        }
        location /error/ {
                alias /var/www/document_errors/;
        }
}
IPCEOF
    log "Fichero IP Nginx corregido: $IP_CONF"
else
    warn "No se encontro $IP_CONF - HestiaCP puede no haberlo generado aun"
fi

# Corregir phpmyadmin.inc - HestiaCP instala version con alias que da 404
# La version correcta usa root en lugar de alias
PMA_INC="/etc/nginx/conf.d/phpmyadmin.inc"
if [ -f "$PMA_INC" ]; then
    cp "$PMA_INC" "$PMA_INC.bak"
    cat > "$PMA_INC" << 'PMAEOF'
location /phpmyadmin {
        root /usr/share/;
        index index.php;
        location ~ /(libraries|setup|templates|locale) {
                deny all;
                return 404;
        }
        location ~ ^/phpmyadmin/(.+\.php)$ {
                root /usr/share/;
                include /etc/nginx/fastcgi_params;
                fastcgi_index index.php;
                fastcgi_param HTTP_EARLY_DATA $rfc_early_data if_not_empty;
                fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
                fastcgi_pass unix:/run/php/www.sock;
        }
        location ~* ^/phpmyadmin/.+\.(jpg|jpeg|gif|css|png|webp|js|ico|html|xml|txt)$ {
                root /usr/share/;
        }
}
PMAEOF
    log "phpmyadmin.inc corregido (root en lugar de alias)"
fi

# ---------------------------------------------
#  PASO 11: VERIFICACION NGINX + REINICIO
# ---------------------------------------------
header "PASO 10C: Parcheando bugs conocidos de HestiaCP"

# --- File Manager: "Error desconocido" al navegar -------------------------
# HestiaAuth.php lee $_SESSION["root"], una clave que el panel NUNCA define.
# Con PHP 8.x eso es un warning que rompe la respuesta del gestor y el
# usuario ve "Error desconocido" al entrar en cualquier carpeta.
FM_AUTH="$HESTIA/web/fm/backend/Services/Auth/Adapters/HestiaAuth.php"
if [[ -f "$FM_AUTH" ]]; then
    if grep -q '\$_SESSION\["look"\] == \$_SESSION\["root"\]' "$FM_AUTH" 2>/dev/null; then
        cp "$FM_AUTH" "$FM_AUTH.qemucp.bak" 2>/dev/null || true
        sed -i 's|\$_SESSION\["look"\] == \$_SESSION\["root"\] &&|$_SESSION["look"] == ($_SESSION["root"] ?? "") \&\&|' \
            "$FM_AUTH" 2>/dev/null || true
        log "File Manager parcheado (SESSION root indefinido)"
    else
        info "File Manager ya parcheado o version distinta"
    fi
fi

# --- Hook de post-actualizacion -------------------------------------------
# IMPORTANTE: el unico hook que HestiaCP ejecuta es
#   /etc/hestiacp/hooks/post_install.sh
# invocado al final del postinst del paquete hestia. La ruta
# /usr/local/hestia/data/hooks/post_update.sh que se usaba antes NO se
# ejecuta NUNCA, por lo que ningun parche se reaplicaba tras un apt upgrade
# (de ahi que el session.save_path duplicado reapareciera una y otra vez).
HOOKFIX="$HESTIA/data/qemucp/instalar-hook.sh"
mkdir -p "$HESTIA/data/qemucp"
cp -a "$AUX_DIR/instalar-hook.sh" "$HOOKFIX"

if [[ -s "$HOOKFIX" ]] && head -1 "$HOOKFIX" | grep -q '^#!/bin/bash'; then
    chmod +x "$HOOKFIX"
    bash "$HOOKFIX" 2>&1 | grep -E "OK|FALLO|AVISO" | sed 's/^/  /' || true
    log "Hook post_install instalado (reaplica los parches en cada apt upgrade)"
else
    warn "No se pudo obtener instalar-hook.sh"
    warn "Los parches NO se reaplicaran tras actualizar hestia. Instalalo con:"
    warn "  bash /root/instalar-hook.sh"
fi


# ---------------------------------------------
#  PASO 10D: LIMITE DE SUBDOMINIOS (estilo cPanel)
# ---------------------------------------------
header "PASO 10D: Limite de subdominios separado del de dominios"

# HestiaCP cuenta cualquier dominio web en WEB_DOMAINS, asi que un subdominio
# gasta el mismo cupo que un dominio adicional y no se pueden hacer planes
# con 0 dominios adicionales y N subdominios como en cPanel.
# El parche anade la clave WEB_SUBDOMAINS a los paquetes y se auto-registra
# en el hook post_install para sobrevivir a los apt upgrade de hestia.
SUBPATCH="$HESTIA/data/qemucp/parche-subdominios.sh"
mkdir -p "$HESTIA/data/qemucp"
cp -a "$AUX_DIR/parche-subdominios.sh" "$SUBPATCH"

if [[ -s "$SUBPATCH" ]] && head -1 "$SUBPATCH" | grep -q '^#!/bin/bash'; then
    chmod +x "$SUBPATCH"
    if bash "$SUBPATCH" >> /var/log/qemucp-subdominios.log 2>&1; then
        log "Limite de subdominios instalado (ver /var/log/qemucp-subdominios.log)"
        info "Los paquetes existentes NO cambian hasta que les pongas"
        info "un valor en 'Web Subdomains' desde Paquetes -> editar"
    else
        warn "El parche de subdominios fallo. Revisa /var/log/qemucp-subdominios.log"
        warn "La instalacion sigue siendo valida, solo sin ese limite separado."
    fi
else
    warn "No se pudo obtener parche-subdominios.sh"
    warn "Dejalo en /root/parche-subdominios.sh y relanza este paso a mano:"
    warn "  bash /root/parche-subdominios.sh"
fi


# ---------------------------------------------
#  PASO 10E: COLA DE REINICIOS (crons de hestiaweb)
# ---------------------------------------------
header "PASO 10E: Verificando la cola de reinicios"

# HestiaCP no reinicia los servicios al crear un dominio: lo apunta en
# $HESTIA/data/queue/restart.pipe y lo procesa un cron del usuario hestiaweb.
# Si ese crontab falta o cron no corre, la zona DNS queda escrita pero named
# nunca la recarga: el dominio "apunta" y no resuelve hasta que se guarda la
# zona a mano desde el panel (eso si fuerza un reinicio inmediato).
# No da ningun error, asi que hay que comprobarlo explicitamente.
CRONTAB_HW="/var/spool/cron/crontabs/hestiaweb"
CRON_ESPERADOS="restart daily disk traffic webstats backup"

# Si tenemos arreglar-crons.sh, usarlo: comprueba las 11 tareas, el modo del
# directorio spool y el sudoers de hestiaweb, no solo las 6 de la cola.
CRONFIX="$HESTIA/data/qemucp/arreglar-crons.sh"
mkdir -p "$HESTIA/data/qemucp"
cp -a "$AUX_DIR/arreglar-crons.sh" "$CRONFIX"
USAR_CRONFIX="no"
if [[ -s "$CRONFIX" ]] && head -1 "$CRONFIX" | grep -q '^#!/bin/bash'; then
    chmod +x "$CRONFIX"
    USAR_CRONFIX="si"
    bash "$CRONFIX" 2>&1 | tee -a /var/log/qemucp-crons.log \
        | grep -E "FALLO|corregido|Todo correcto" | sed 's/^/  /' || true
    log "Cola de reinicios verificada con arreglar-crons.sh"
fi

FALTANTES=""
if [[ "$USAR_CRONFIX" == "no" ]]; then
for Q in $CRON_ESPERADOS; do
    grep -q "v-update-sys-queue $Q" "$CRONTAB_HW" 2>/dev/null || FALTANTES="$FALTANTES $Q"
done

if [[ ! -f "$CRONTAB_HW" ]]; then
    warn "No existe $CRONTAB_HW: la cola de reinicios NO funciona"
    FALTANTES="$CRON_ESPERADOS"
fi

if [[ -n "$FALTANTES" ]]; then
    warn "Faltan trabajos en la cola:$FALTANTES"
    info "Regenerando el crontab de hestiaweb..."
    mkdir -p /var/spool/cron/crontabs
    if [[ ! -f "$CRONTAB_HW" ]]; then
        {
            echo 'MAILTO=""'
            echo 'CONTENT_TYPE="text/plain; charset=utf-8"'
        } > "$CRONTAB_HW"
    fi
    LE_MIN=$((RANDOM % 60)); LE_HOUR=$((RANDOM % 5))
    add_cron() {
        grep -q "$2" "$CRONTAB_HW" 2>/dev/null || echo "$1 sudo /usr/local/hestia/bin/$2" >> "$CRONTAB_HW"
    }
    add_cron '*/2 * * * *'  'v-update-sys-queue restart'
    add_cron '10 00 * * *'  'v-update-sys-queue daily'
    add_cron '15 02 * * *'  'v-update-sys-queue disk'
    add_cron '10 00 * * *'  'v-update-sys-queue traffic'
    add_cron '30 03 * * *'  'v-update-sys-queue webstats'
    add_cron '*/5 * * * *'  'v-update-sys-queue backup'
    add_cron '10 05 * * *'  'v-backup-users'
    add_cron '20 00 * * *'  'v-update-user-stats'
    add_cron '*/5 * * * *'  'v-update-sys-rrd'
    add_cron "$LE_MIN $LE_HOUR * * *" 'v-update-letsencrypt-ssl'
    chown hestiaweb:crontab "$CRONTAB_HW" 2>/dev/null || chown hestiaweb "$CRONTAB_HW" 2>/dev/null || true
    chmod 600 "$CRONTAB_HW" 2>/dev/null || true
    log "Crontab de hestiaweb regenerado ($(grep -c "v-" "$CRONTAB_HW") trabajos)"
else
    log "Cola de reinicios correcta ($(grep -c "v-" "$CRONTAB_HW") trabajos)"
fi
fi   # fin de: if [[ "$USAR_CRONFIX" == "no" ]]

# Propietario y permisos SIEMPRE, con o sin tareas faltantes: si el fichero
# no es de hestiaweb con modo 600, cron lo descarta sin registrar nada.
if [[ -f "$CRONTAB_HW" ]]; then
    DUENO_HW=$(stat -c '%U' "$CRONTAB_HW" 2>/dev/null || echo "?")
    MODO_HW=$(stat -c '%a' "$CRONTAB_HW" 2>/dev/null || echo "?")
    if [[ "$DUENO_HW" != "hestiaweb" || "$MODO_HW" != "600" ]]; then
        chown hestiaweb:hestiaweb "$CRONTAB_HW" 2>/dev/null \
            || chown hestiaweb "$CRONTAB_HW" 2>/dev/null || true
        chmod 600 "$CRONTAB_HW" 2>/dev/null || true
        log "Crontab de hestiaweb: propietario/permisos corregidos (eran $DUENO_HW/$MODO_HW)"
    fi
fi
chmod 1730 /var/spool/cron/crontabs 2>/dev/null || true

# El cron tiene que estar activo, o el crontab no sirve de nada
systemctl enable cron >/dev/null 2>&1 || true
if systemctl is-active --quiet cron 2>/dev/null; then
    log "Servicio cron activo"
else
    systemctl restart cron >/dev/null 2>&1
    if systemctl is-active --quiet cron 2>/dev/null; then
        log "Servicio cron arrancado"
    else
        warn "cron NO arranca: los dominios nuevos no resolveran hasta"
        warn "ejecutar 'v-restart-dns yes' a mano. Revisa: systemctl status cron"
    fi
fi

# Vaciar lo que haya quedado encolado durante la instalacion y recargar named,
# que el PASO 11 no toca.
$HESTIA/bin/v-restart-dns yes >/dev/null 2>&1 || true
$HESTIA/bin/v-restart-web yes >/dev/null 2>&1 || true
$HESTIA/bin/v-restart-proxy yes >/dev/null 2>&1 || true
log "Cola vaciada y DNS/web recargados"

# Prueba real: crear una zona de usar y tirar y ver si named la resuelve.
# Es la unica forma de saber que el circuito completo funciona.
ZONA_TEST="qemucp-test-$(date +%s).local"
if $HESTIA/bin/v-add-dns-domain admin "$ZONA_TEST" 127.0.0.1 >/dev/null 2>&1; then
    sleep 2
    $HESTIA/bin/v-restart-dns yes >/dev/null 2>&1 || true
    sleep 1
    if dig +short +time=3 +tries=1 "@127.0.0.1" "$ZONA_TEST" A 2>/dev/null | grep -q .; then
        log "Comprobado: named sirve las zonas nuevas correctamente"
    else
        warn "named NO resuelve una zona recien creada."
        warn "Los dominios nuevos no se veran hasta recargar DNS a mano."
        warn "Revisa: named-checkconf && systemctl status named"
    fi
    $HESTIA/bin/v-delete-dns-domain admin "$ZONA_TEST" >/dev/null 2>&1 || true
    $HESTIA/bin/v-restart-dns yes >/dev/null 2>&1 || true
else
    info "No se pudo crear la zona de prueba (se omite la comprobacion)"
fi


header "PASO 11: Verificando configuracion y reiniciando servicios"

# VERIFICACION CRITICA Y COMPLETA de hestia.conf
# Una instalacion interrumpida (o un 'apt reinstall hestia') puede dejar
# valores sin escribir. Sin ellos:
#   - Faltan pestanas del panel (BBDD, DNS, RESPALDOS, Firewall...)
#   - Al crear dominios: "WEB_SYSTEM is not enabled" o listen sin puerto
#     ("invalid port") -> nginx no arranca -> creacion de dominio falla.
# Reparamos TODOS los valores criticos, cada uno segun el servicio activo.
HCONF="/usr/local/hestia/conf/hestia.conf"

# --- Helper: escribe KEY='VALUE' si la clave no existe ---
ensure_conf() {
    local key="$1" val="$2"
    if ! grep -q "^${key}=" "$HCONF" 2>/dev/null; then
        echo "${key}='${val}'" >> "$HCONF"
        log "hestia.conf reparado: ${key}='${val}'"
    fi
}

# --- Valores WEB basicos (sin ellos no se pueden crear dominios) ---
if systemctl is-active --quiet apache2 2>/dev/null; then
    ensure_conf "WEB_SYSTEM" "apache2"
elif systemctl is-active --quiet nginx 2>/dev/null; then
    ensure_conf "WEB_SYSTEM" "nginx"
fi
ensure_conf "WEB_BACKEND" "php-fpm"
ensure_conf "WEB_SSL" "mod_ssl"
systemctl is-active --quiet nginx 2>/dev/null && ensure_conf "PROXY_SYSTEM" "nginx"

# --- PUERTOS web (sin ellos el listen sale sin puerto -> nginx no arranca) ---
# Stack QemuCP: nginx (proxy) 80/443 delante de apache (backend) 8080/8443
ensure_conf "WEB_PORT" "8080"
ensure_conf "WEB_SSL_PORT" "8443"
ensure_conf "PROXY_PORT" "80"
ensure_conf "PROXY_SSL_PORT" "443"

# --- Otros sistemas de correo/stats/webmail ---
systemctl is-active --quiet exim4 2>/dev/null && ensure_conf "MAIL_SYSTEM" "exim4"
ensure_conf "STATS_SYSTEM" "awstats"
[ -d /var/www/webmail ] || [ -d "$HESTIA/web/webmail" ] || systemctl is-active --quiet apache2 2>/dev/null && ensure_conf "WEBMAIL_SYSTEM" "roundcube"

log "Valores web basicos y puertos verificados"


# --- DB_SYSTEM (pestana BBDD) ---
if ! grep -q "^DB_SYSTEM=" "$HCONF" 2>/dev/null; then
    warn "DB_SYSTEM no encontrado - reparando..."
    if systemctl is-active --quiet mariadb 2>/dev/null || systemctl is-active --quiet mysql 2>/dev/null; then
        echo "DB_SYSTEM='mysql'" >> "$HCONF"
        $HESTIA/bin/v-add-database-host mysql localhost root '' 2>/dev/null || true
        log "DB_SYSTEM reparado: MariaDB registrado"
    else
        warn "MariaDB/MySQL no activo - revisa: systemctl status mariadb"
    fi
else
    log "DB_SYSTEM presente (OK)"
fi

# --- DNS_SYSTEM (pestana DNS) ---
if ! grep -q "^DNS_SYSTEM=" "$HCONF" 2>/dev/null; then
    warn "DNS_SYSTEM no encontrado - reparando..."
    if systemctl is-active --quiet named 2>/dev/null || systemctl is-active --quiet bind9 2>/dev/null; then
        echo "DNS_SYSTEM='bind9'" >> "$HCONF"
        log "DNS_SYSTEM reparado: BIND registrado"
    else
        warn "BIND/named no activo - la pestana DNS no aparecera"
    fi
else
    log "DNS_SYSTEM presente (OK)"
fi

# --- BACKUP_SYSTEM (pestana RESPALDOS) ---
if ! grep -q "^BACKUP_SYSTEM=" "$HCONF" 2>/dev/null; then
    warn "BACKUP_SYSTEM no encontrado - reparando..."
    echo "BACKUP_SYSTEM='local'" >> "$HCONF"
    log "BACKUP_SYSTEM reparado: backup local activado"
else
    log "BACKUP_SYSTEM presente (OK)"
fi

# --- FIREWALL_SYSTEM (icono Firewall + Fail2ban) ---
if ! grep -q "^FIREWALL_SYSTEM=" "$HCONF" 2>/dev/null; then
    warn "FIREWALL_SYSTEM no encontrado - reparando..."
    if command -v iptables >/dev/null 2>&1; then
        echo "FIREWALL_SYSTEM='iptables'" >> "$HCONF"
        log "FIREWALL_SYSTEM reparado: iptables registrado"
        # Si fail2ban esta activo, registrarlo como extension del firewall
        if systemctl is-active --quiet fail2ban 2>/dev/null; then
            grep -q "^FIREWALL_EXTENSION=" "$HCONF" || echo "FIREWALL_EXTENSION='fail2ban'" >> "$HCONF"
            log "FIREWALL_EXTENSION reparado: fail2ban registrado"
        fi
    else
        warn "iptables no disponible - el icono Firewall no aparecera"
    fi
else
    log "FIREWALL_SYSTEM presente (OK)"
fi

# --- IMAP_SYSTEM (correo IMAP) ---
if ! grep -q "^IMAP_SYSTEM=" "$HCONF" 2>/dev/null; then
    if systemctl is-active --quiet dovecot 2>/dev/null; then
        echo "IMAP_SYSTEM='dovecot'" >> "$HCONF"
        log "IMAP_SYSTEM reparado: dovecot registrado"
    fi
else
    log "IMAP_SYSTEM presente (OK)"
fi

# --- SIEVE_SYSTEM (filtros de correo) ---
if ! grep -q "^SIEVE_SYSTEM=" "$HCONF" 2>/dev/null; then
    if systemctl is-active --quiet dovecot 2>/dev/null; then
        echo "SIEVE_SYSTEM='yes'" >> "$HCONF"
        log "SIEVE_SYSTEM reparado: sieve activado"
    fi
else
    log "SIEVE_SYSTEM presente (OK)"
fi

# --- ANTISPAM_SYSTEM (antispam correo) ---
if ! grep -q "^ANTISPAM_SYSTEM=" "$HCONF" 2>/dev/null; then
    if systemctl is-active --quiet spamassassin 2>/dev/null || systemctl is-active --quiet spamd 2>/dev/null; then
        echo "ANTISPAM_SYSTEM='spamassassin'" >> "$HCONF"
        log "ANTISPAM_SYSTEM reparado: spamassassin registrado"
    fi
else
    log "ANTISPAM_SYSTEM presente (OK)"
fi

# --- ANTIVIRUS_SYSTEM (antivirus correo) ---
if ! grep -q "^ANTIVIRUS_SYSTEM=" "$HCONF" 2>/dev/null; then
    if systemctl is-active --quiet clamav-daemon 2>/dev/null; then
        echo "ANTIVIRUS_SYSTEM='clamav'" >> "$HCONF"
        log "ANTIVIRUS_SYSTEM reparado: clamav registrado"
    fi
else
    log "ANTIVIRUS_SYSTEM presente (OK)"
fi

# --- FTP_SYSTEM (acceso FTP) ---
if ! grep -q "^FTP_SYSTEM=" "$HCONF" 2>/dev/null; then
    if systemctl is-active --quiet vsftpd 2>/dev/null; then
        echo "FTP_SYSTEM='vsftpd'" >> "$HCONF"
        log "FTP_SYSTEM reparado: vsftpd registrado"
    elif systemctl is-active --quiet proftpd 2>/dev/null; then
        echo "FTP_SYSTEM='proftpd'" >> "$HCONF"
        log "FTP_SYSTEM reparado: proftpd registrado"
    fi
else
    log "FTP_SYSTEM presente (OK)"
fi


# Test de configuracion Nginx antes de reiniciar
# Si falla, avisamos con el detalle pero NO abortamos: intentamos arreglar
# desactivando GeoIP2 (causa mas comun) y reintentamos.
if nginx -t 2>/tmp/nginx_test.log; then
    log "nginx -t: configuracion valida"
else
    warn "nginx -t fallo. Detalle:"
    cat /tmp/nginx_test.log | sed 's/^/    /'
    # Intento de auto-reparacion: si el fallo es por GeoIP2, desactivarlo
    if grep -qi "geoip2\|GeoIP2-Country.mmdb" /tmp/nginx_test.log; then
        warn "Desactivando GeoIP2 para que nginx arranque..."
        sed -i 's|^geoip2 |#geoip2 |; /^geoip2 /,/^}/s|^|#|' /etc/nginx/conf.d/00-init.conf 2>/dev/null || true
        # Recrear 00-init sin geoip2, con variable por defecto
        cat > /etc/nginx/conf.d/00-init.conf << 'GEOOFF'
map $http_x_forwarded_for $realip {
    ~^(\d+\.\d+\.\d+\.\d+) $1;
    default $remote_addr;
}
map $realip $geoip2_data_country_code {
    default "ES";
}
GEOOFF
    fi
    # Reintentar
    if nginx -t 2>/tmp/nginx_test2.log; then
        log "nginx -t: valido tras auto-reparacion (GeoIP2 desactivado)"
    else
        warn "nginx sigue con errores. Detalle:"
        cat /tmp/nginx_test2.log | sed 's/^/    /'
        warn "El panel puede seguir accesible via su propio nginx (hestia-nginx)."
        warn "Revisa /etc/nginx/conf.d/ manualmente. La instalacion continua."
    fi
fi

systemctl restart mariadb 2>/dev/null && log "MariaDB reiniciado" || warn "MariaDB: reinicia manualmente con: systemctl restart mariadb"
systemctl restart redis-server 2>/dev/null && log "Redis reiniciado"
systemctl restart apache2 2>/dev/null  && log "Apache reiniciado"
systemctl restart nginx 2>/dev/null    && log "Nginx reiniciado (GeoIP2 + Brotli activos)"
systemctl restart hestia   && log "QemuCP reiniciado"
systemctl enable fail2ban 2>/dev/null || true
systemctl restart fail2ban 2>/dev/null && log "Fail2ban activado y reiniciado"

for VER in "${PHP_VERSIONS[@]}"; do
    systemctl restart "php${VER}-fpm" 2>/dev/null && \
        log "PHP $VER FPM reiniciado" || true
done

# ---------------------------------------------
#  RESUMEN FINAL
# ---------------------------------------------
PANEL_IP=$(hostname -I | awk '{print $1}')
CREDS_FILE="/root/qemucp-credentials.txt"

cat > "$CREDS_FILE" << CREDSEOF
===============================================
  QemuCP - Credenciales de acceso
  Generado: $(date '+%d/%m/%Y %H:%M:%S')
===============================================

  Panel URL:   https://$PANEL_IP:$HESTIA_PORT
  Panel URL:   https://$HOSTNAME:$HESTIA_PORT
  Usuario:     admin
  Password:    $ADMIN_PASS
  Email:       $ADMIN_EMAIL

  PHP:         7.4 * 8.0 * 8.1 * 8.2 * 8.3 * 8.4
  MariaDB:     Version instalada por QemuCP
  GeoIP2:      Activo (bloqueo por pais + bots)
  Idioma:      Espanol  |  Tema: Dark

  ? Elimina este archivo tras anotarlo:
     rm -f $CREDS_FILE

===============================================
CREDSEOF
chmod 600 "$CREDS_FILE" 2>/dev/null || true

echo ""
echo -e "${GREEN}+==========================================================+${NC}"
echo -e "${GREEN}|          QemuCP instalado y configurado                  |${NC}"
echo -e "${GREEN}+==========================================================+${NC}"
echo ""
echo -e "  ${BLUE}Panel URL:${NC}     https://$PANEL_IP:$HESTIA_PORT"
echo -e "  ${BLUE}Panel URL:${NC}     https://$HOSTNAME:$HESTIA_PORT"
echo -e "  ${BLUE}Usuario:${NC}       admin"
echo -e "  ${BLUE}Password:${NC}      ${RED}$ADMIN_PASS${NC}"
echo -e "  ${BLUE}Email:${NC}         $ADMIN_EMAIL"
echo ""
echo -e "  ${YELLOW}Credenciales guardadas en:${NC} $CREDS_FILE ${YELLOW}(chmod 600)${NC}"
echo ""
echo -e "  ${YELLOW}Configuracion aplicada:${NC}"
echo -e "  OK Marca:       QemuCP * logo transparente * referencias eliminadas"
echo -e "  OK Tema:        Dark * Idioma: Espanol (admin + nuevos usuarios)"
echo -e "  OK PHP:         7.4 * 8.0 * 8.1 * 8.2 * 8.3 * 8.4 (512M * JIT 8+)"
echo -e "  OK MariaDB:     10.11 LTS * InnoDB ${INNODB_BUFFER}MB buffer"
echo -e "  OK Nginx:       Proxy inverso * FastCGI cache * GeoIP2 * Brotli activo"
echo -e "  OK Redis:       Cache de objetos en RAM * ${REDIS_MEM}MB * LRU"
echo -e "  OK FastCGI:     Cache de paginas completas * bypass WP/PS automatico"
echo -e "  OK Brotli:      Compresion avanzada (CSS*JS*HTML*JSON*fonts)"
echo -e "  OK GeoIP2:      Bloqueo RU,UA,VN,SG,CN,JP,IN,KR,MD * bots 444"
echo -e "  OK Whitelist:   78.128.8.207 * 127.0.0.1 (bypass GeoIP+bots)"
echo -e "  OK Apache:      Motor web backend optimizado"
echo -e "  OK SSL:         Let's Encrypt * renovacion automatica 3:00 AM"
echo -e "  OK Fail2ban:    SSH * Nginx * Panel * MySQL (ban 24h en remoto)"
echo -e "  OK Kernel:      TCP stack * file descriptors optimizados"
echo -e "  OK Timezone:    Europe/Madrid
  OK Parches:     #1 FileManager SFTP * #2 PubkeyAuth * #3 SFTP homedir
                 #4 SpamAssassin spamd * #5 Roundcube permisos * #6 phpMyAdmin * #7 SSL cron"
echo ""
echo -e "  ${YELLOW}Archivos GeoIP2 editables:${NC}"
echo -e "  ? Paises bloqueados:  /etc/nginx/conf.d/lists/countries.list"
echo -e "  ? Bots bloqueados:    /etc/nginx/conf.d/lists/bots.list"
echo -e "  ? IPs permitidas:     /etc/nginx/conf.d/lists/whitelist.list"
echo -e "  ? Reglas activas:     /etc/nginx/conf.d/server-includes/main-rules.conf"
echo ""
echo -e "  ${RED}IMPORTANTE:${NC}"
echo -e "  ? Apunta el DNS de $HOSTNAME a $PANEL_IP antes de usar SSL"
echo -e "  ? Elimina /root/qemucp-credentials.txt tras anotar la contrasena"
echo -e "  ? Para anadir/quitar paises edita countries.list y recarga nginx"
echo ""
echo -e "${GREEN}==========================================================${NC}"

# Temporales de la instalacion. Los scripts auxiliares ya estan copiados en
# $HESTIA/data/qemucp, que es desde donde los usa el hook post_install.
rm -rf /opt/qemucp /opt/qemucp-src /tmp/hestiacp-src 2>/dev/null || true

# Autoborrado del script de instalacion (al final, tras completar todos los pasos)
rm -f "$0" 2>/dev/null || true
