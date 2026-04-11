#!/bin/bash
# ============================================================
# QemuCP - Instalador de OpenLiteSpeed
# Instala OLS como motor web alternativo seleccionable
# desde el panel de QemuCP
# ============================================================

set -euo pipefail
HESTIA=/usr/local/hestia

log()   { echo "[OK] $1"; }
warn()  { echo "[!] $1"; }
error() { echo "[!!] $1"; exit 1; }

[[ $EUID -ne 0 ]] && error "Ejecuta como root"
[[ ! -d "$HESTIA" ]] && error "QemuCP no esta instalado"

log "Iniciando instalacion de OpenLiteSpeed..."

# Instalar repositorio OLS
wget -q --timeout=30 -O /tmp/ols.rpm.key \
    https://rpms.litespeedtech.com/debian/lst_debian_repo.gpg 2>/dev/null || true
curl -fsSL https://repo.litespeed.sh | bash -s -- --lsws 2>/dev/null || {
    # Fallback: repo manual
    wget -q --timeout=30 -O - http://rpms.litespeedtech.com/debian/enable_lst_debian_repo.sh | bash
}

apt-get update -qq
apt-get install -y -qq openlitespeed 2>/dev/null || \
    error "No se pudo instalar OpenLiteSpeed"

# Instalar lsphp para las versiones soportadas
PHP_VERSIONS=("83" "82" "81" "80" "74")
for VER in "${PHP_VERSIONS[@]}"; do
    apt-get install -y -qq "lsphp${VER}" "lsphp${VER}-common" \
        "lsphp${VER}-mysql" "lsphp${VER}-opcache" \
        "lsphp${VER}-curl" "lsphp${VER}-imagick" 2>/dev/null || \
        warn "lsphp${VER} no disponible, continuando..."
done

log "OpenLiteSpeed y lsphp instalados"

# Crear directorio de logs
mkdir -p /usr/local/lsws/logs/domains
chown -R nobody:nogroup /usr/local/lsws/logs 2>/dev/null || true

# Crear directorio de vhosts
mkdir -p /usr/local/lsws/conf/vhosts

# Copiar templates OLS al directorio de HestiaCP
OLS_TPL_SRC="$HESTIA/data/templates/web/openlitespeed"
if [ -d "$OLS_TPL_SRC" ]; then
    log "Templates OLS ya presentes"
else
    mkdir -p "$OLS_TPL_SRC/php-fpm"
    cp -r /usr/local/hestia/install/deb/templates/web/openlitespeed/* \
        "$OLS_TPL_SRC/" 2>/dev/null || warn "No se pudieron copiar templates OLS"
fi

# Configurar OLS para funcionar con QemuCP
OLS_CONF="/usr/local/lsws/conf/httpd_config.conf"
if [ -f "$OLS_CONF" ]; then
    # Cambiar usuario a www-data para compatibilidad con HestiaCP
    sed -i 's/user\s*nobody/user www-data/' "$OLS_CONF" 2>/dev/null || true
    sed -i 's/group\s*nogroup/group www-data/' "$OLS_CONF" 2>/dev/null || true
    log "OLS configurado con usuario www-data"
fi

# Configurar puerto OLS (no puede coincidir con Nginx)
# OLS en modo backend: puerto 8088
OLS_HTTP_PORT=8088
OLS_HTTPS_PORT=8443

if [ -f "$OLS_CONF" ]; then
    sed -i "s/port\s*80\b/port $OLS_HTTP_PORT/" "$OLS_CONF" 2>/dev/null || true
    log "OLS configurado en puerto $OLS_HTTP_PORT"
fi

# Habilitar OLS como opcion en QemuCP
# Añadir a la configuracion de hestia
HESTIA_CONF="$HESTIA/conf/hestia.conf"
if ! grep -q "OLS_SYSTEM" "$HESTIA_CONF" 2>/dev/null; then
    echo "OLS_SYSTEM='openlitespeed'" >> "$HESTIA_CONF"
    echo "OLS_PORT='$OLS_HTTP_PORT'" >> "$HESTIA_CONF"
    echo "OLS_SSL_PORT='$OLS_HTTPS_PORT'" >> "$HESTIA_CONF"
    log "OLS registrado en configuracion de QemuCP"
fi

# Habilitar e iniciar OLS
systemctl enable lsws 2>/dev/null || true
systemctl start lsws 2>/dev/null || warn "No se pudo iniciar OLS - verifica manualmente"

log "OpenLiteSpeed instalado correctamente"
log "Para asignar OLS a un dominio:"
log "  v-change-web-domain-backend USUARIO DOMINIO openlitespeed"
