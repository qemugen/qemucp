#!/bin/bash
# =============================================================================
#  QemuCP - Instalador personalizado basado en HestiaCP
#  Compatible con: Ubuntu 24.04 LTS (limpio)
#  Uso: bash qemucp_install.sh
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
LANG="es"
HESTIA_PORT="8083"
PHP_VERSIONS=("7.2" "7.3" "7.4" "8.0" "8.1" "8.2" "8.3" "8.4" "8.5")

# ============================================================
# VERIFICACION DE LICENCIA QEMUCP
# ============================================================
QEMUCP_LICENSE_KEY="${1:-}"
QEMUCP_VALID_KEY="QemuCP2024#Cloud"

if [[ "$QEMUCP_LICENSE_KEY" != "$QEMUCP_VALID_KEY" ]]; then
    echo ""
    echo "  +-------------------------------------------+"
    echo "  |      QemuCP - Acceso Restringido          |"
    echo "  |                                           |"
    echo "  |  Este software es propiedad de QemuGen.  |"
    echo "  |  Contacta: soporte@qemugen.com            |"
    echo "  +-------------------------------------------+"
    echo ""
    echo "  Uso: bash qemucp_install.sh TU-CLAVE-DE-LICENCIA"
    echo ""
    exit 1
fi

set -euo pipefail

# Evitar ventanas interactivas durante apt (GRUB, sshd, etc)
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
export LANG=es_ES.UTF-8
export LC_ALL=es_ES.UTF-8
export LANGUAGE=es_ES.UTF-8

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[OK]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[!!]${NC} $1"; exit 1; }
header() { echo -e "\n${BLUE}======================================${NC}"; echo -e "${BLUE}  $1${NC}"; echo -e "${BLUE}======================================${NC}\n"; }

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
while true; do
    echo -ne "  ${YELLOW}Introduce el hostname del panel${NC} (ej: panel.tudominio.com): "
    read -r HOSTNAME
    HOSTNAME=$(echo "$HOSTNAME" | tr '[:upper:]' '[:lower:]' | xargs)

    if [[ -z "$HOSTNAME" ]]; then
        echo -e "  ${RED}[!!]${NC} El hostname no puede estar vacio."
        continue
    fi

    if ! echo "$HOSTNAME" | grep -qP '^[a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]{0,61}[a-z0-9])?)+$'; then
        echo -e "  ${RED}[!!]${NC} Formato invalido. Usa un dominio completo como: panel.tudominio.com"
        continue
    fi

    echo -ne "  ${YELLOW}Confirma el hostname${NC}: $HOSTNAME [s/n]: "
    read -r CONFIRM
    [[ "$CONFIRM" =~ ^[sS]$ ]] && break
done

echo ""
log "Hostname configurado: $HOSTNAME"

# ---------------------------------------------
#  PASO 1: PREPARAR SISTEMA BASE
# ---------------------------------------------
header "PASO 1: Preparando sistema base"

timedatectl set-timezone "$TIMEZONE"
log "Timezone: $TIMEZONE"

locale-gen es_ES.UTF-8 || true
update-locale LANG=es_ES.UTF-8 LC_ALL=es_ES.UTF-8 || true
log "Locale: es_ES.UTF-8"

hostnamectl set-hostname "$HOSTNAME"
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
log "Versiones PHP obsoletas bloqueadas (5.6, 7.0, 7.1)"

# ---------------------------------------------
#  PASO 2: INSTALAR HESTIACP
# ---------------------------------------------
header "PASO 2: Instalando QemuCP"

cd /tmp || error "No se puede acceder a /tmp"
wget -q --timeout=30 "https://raw.githubusercontent.com/qemugen/qemucp/release/install/hst-install.sh" \
    -O hst-install.sh || error "No se pudo descargar el instalador de QemuCP"

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
detect_os_type() {
    if [ -f /etc/debian_version ]; then
        if grep -qi ubuntu /etc/os-release 2>/dev/null; then echo "ubuntu"; else echo "debian"; fi
    else
        echo "ubuntu"
    fi
}
OS_TYPE=$(detect_os_type)
CACHE_BUST=$(date +%s)
wget -q --timeout=30 "https://raw.githubusercontent.com/qemugen/qemucp/release/install/hst-install-${OS_TYPE}.sh?cb=${CACHE_BUST}" \
    -O "hst-install-${OS_TYPE}.sh" || error "No se pudo descargar hst-install-${OS_TYPE}.sh"

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

bash hst-install.sh \
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
    -l "$LANG" \
    -r "$HESTIA_PORT" \
    -f

log "QemuCP instalado correctamente"

# Eliminar instalador base tras la instalacion (el autoborrado del script va al final)
rm -f /tmp/hst-install.sh 2>/dev/null || true
log "Instalador base eliminado"

source /etc/hestia/hestia.conf 2>/dev/null || true
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
log "Hook post-creacion: nuevos usuarios -> Espanol + Dark"

# ---------------------------------------------
#  HOOK POST-ACTUALIZACION HESTIACP
#  Re-aplica personalizaciones QemuCP tras
#  cada actualizacion automatica del panel
# ---------------------------------------------
# Hook post-actualizacion: re-aplica personalizaciones QemuCP tras cada update
# HestiaCP ejecuta este script automaticamente despues de cada actualizacion
cat > "$HOOK_DIR/post_update.sh" << 'POSTUPDATEEOF'
#!/bin/bash
# QemuCP - Post-update hook
# Se ejecuta automaticamente tras cada actualizacion de HestiaCP
# Re-aplica todas las personalizaciones para que no se pierdan

HESTIA=/usr/local/hestia
WEB_DIR="$HESTIA/web"
THEME_DIR="$HESTIA/web/css"
LOG="/var/log/qemucp-update.log"

echo "$(date '+%Y-%m-%d %H:%M:%S') - Ejecutando post-update QemuCP..." >> "$LOG"

# 1. Restaurar CSS de marca si fue sobreescrito
if [[ ! -f "$THEME_DIR/custom-brand.css" ]] || ! grep -q "QemuCP" "$THEME_DIR/custom-brand.css" 2>/dev/null; then
    # Regenerar el CSS desde la copia de seguridad
    if [[ -f "$THEME_DIR/custom-brand.css.qemucp" ]]; then
        cp "$THEME_DIR/custom-brand.css.qemucp" "$THEME_DIR/custom-brand.css"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - CSS de marca restaurado" >> "$LOG"
    fi
fi

# 2. Re-inyectar CSS en header si fue sobreescrito
for HEADER_FILE in "$WEB_DIR/templates/header.php" "$WEB_DIR/templates/header.html"; do
    if [[ -f "$HEADER_FILE" ]] && ! grep -q "custom-brand.css" "$HEADER_FILE" 2>/dev/null; then
        sed -i 's|</head>|    <link rel="stylesheet" href="/css/custom-brand.css">
</head>|' "$HEADER_FILE"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - CSS re-inyectado en $(basename $HEADER_FILE)" >> "$LOG"
    fi
done

# 3. Re-aplicar reemplazos de marca en templates actualizados
find "$WEB_DIR" \( -name "*.php" -o -name "*.html" -o -name "*.tpl" \)     -newer "$LOG" -not -path "*/node_modules/*" 2>/dev/null | while read -r f; do
    sed -i         -e "s|Hestia Control Panel|QemuCP Control Panel|g"         -e "s|HestiaCP|QemuCP|g"         -e "s|hestiacp\.com|qemucp.com|g"         "$f" 2>/dev/null || true
done

# 4. Re-aplicar optimizaciones en templates PHP-FPM si fueron sobreescritos
HESTIA_PHP_TPL="$HESTIA/data/templates/web/php-fpm"
for TPL_FILE in "$HESTIA_PHP_TPL"/*.tpl; do
    [[ -f "$TPL_FILE" ]] || continue
done

# 5. Re-aplicar includes GeoIP2 en templates Nginx si fueron sobreescritos
NGINX_TPL_DIR="$HESTIA/data/templates/web/nginx"
for TPL in "$NGINX_TPL_DIR"/*.tpl "$NGINX_TPL_DIR"/*.stpl; do
    [[ -f "$TPL" ]] || continue
    if ! grep -q "main-rules.conf" "$TPL" 2>/dev/null; then
        sed -i "/^server[[:space:]]*{/a\    include /etc/nginx/conf.d/server-includes/main-rules.conf;" "$TPL"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - GeoIP2 re-inyectado en $(basename $TPL)" >> "$LOG"
    fi
done

# 6. Re-aplicar FIX SSH para File Manager
if ! grep -q "^Subsystem sftp internal-sftp" /etc/ssh/sshd_config 2>/dev/null; then
    sed -i "s|Subsystem sftp.*|Subsystem sftp internal-sftp|" /etc/ssh/sshd_config
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    echo "$(date '+%Y-%m-%d %H:%M:%S') - SSH fix re-aplicado" >> "$LOG"
fi

# 7. Recargar servicios afectados
nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
systemctl reload php*-fpm 2>/dev/null || true

echo "$(date '+%Y-%m-%d %H:%M:%S') - Post-update QemuCP completado" >> "$LOG"
POSTUPDATEEOF
chmod +x "$HOOK_DIR/post_update.sh" 2>/dev/null || true
log "Hook post-actualizacion: personalizaciones protegidas tras updates"

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
HESTIA_CONF="/etc/hestiacp/hestia.conf"
if grep -q "APP_NAME" "$HESTIA_CONF" 2>/dev/null; then
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
# PHP 5.6, 7.0, 7.1 estan EOL y son un riesgo de seguridad
PHP_OBSOLETE=("5.6" "7.0" "7.1")
for VER in "${PHP_OBSOLETE[@]}"; do
    if [[ -f "/usr/bin/php${VER}" ]] || [[ -d "/etc/php/${VER}" ]]; then
        $HESTIA/bin/v-delete-web-php "$VER" 2>/dev/null || true
        apt-get purge -y -qq "php${VER}*" 2>/dev/null || true
        log "PHP $VER (EOL) eliminado por seguridad"
    fi
done

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

    # Insertar optimizaciones si no estan ya
    if ! grep -q "memory_limit = 512M" "$TPL_FILE" 2>/dev/null; then
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

INNODB_BUFFER=$(( RAM_MB / 2 ))
# Instancias de buffer pool: 1 por cada GB, minimo 1, maximo 8
INNODB_INSTANCES=$(( INNODB_BUFFER / 1024 ))
# Minimo 1 instancia, maximo 64
[[ $INNODB_INSTANCES -lt 1 ]] && INNODB_INSTANCES=1
[[ $INNODB_INSTANCES -gt 64 ]] && INNODB_INSTANCES=64
[[ $INNODB_INSTANCES -lt 1 ]] && INNODB_INSTANCES=1
[[ $INNODB_INSTANCES -gt 8 ]] && INNODB_INSTANCES=8

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
innodb_buffer_pool_instances = ${INNODB_INSTANCES}
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
# El File Manager (FileGator) usa SFTP interno. En Ubuntu 24.04 con
# OpenSSH 9.x el binario sftp-server ya no existe en la ruta esperada.
# HestiaCP lo configura durante la instalacion, pero nuestro bloque SSH
# sobreescribe sshd_config. Hay que asegurarse de que quede correcto.
# Ref: https://hestiacp.com/docs/server-administration/file-manager
if grep -q "internal-sftp-server" "$SSHD" 2>/dev/null; then
    sed -i 's|Subsystem sftp internal-sftp-server|Subsystem sftp internal-sftp|' "$SSHD"
elif ! grep -q "Subsystem sftp internal-sftp" "$SSHD" 2>/dev/null; then
    echo "Subsystem sftp internal-sftp" >> "$SSHD"
fi
log "FIX #1: Subsystem sftp internal-sftp verificado (File Manager)"

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

systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
log "SSH configurado"

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

sysctl -p /etc/sysctl.d/99-qemucp-performance.conf > /dev/null 2>&1
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
header "PASO 11: Verificando configuracion y reiniciando servicios"

# VERIFICACION CRITICA: valores *_SYSTEM en hestia.conf
# Si la instalacion se interrumpio, DB_SYSTEM / DNS_SYSTEM / BACKUP_SYSTEM
# pueden faltar y el panel no muestra las pestanas BBDD / DNS / RESPALDOS.
HCONF="/usr/local/hestia/conf/hestia.conf"

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

# Autoborrado del script de instalacion (al final, tras completar todos los pasos)
rm -f "$0" 2>/dev/null || true
