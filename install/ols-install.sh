#!/bin/bash
# ============================================================
# QemuCP - Instalador de OpenLiteSpeed
# Instala OLS como motor web alternativo seleccionable
# desde el panel de QemuCP
#
# IMPORTANTE: OLS se instala en modo BACKEND (puertos 8088/8488)
# Nginx sigue siendo el proxy frontal en puertos 80/443
# NO hay conflicto con la configuracion existente de QemuCP
# ============================================================

HESTIA=/usr/local/hestia

log()   { echo "[OK] $1"; }
warn()  { echo "[!] $1"; }
error() { echo "[!!] $1"; exit 1; }

[[ $EUID -ne 0 ]] && error "Ejecuta como root"
[[ ! -d "$HESTIA" ]] && error "QemuCP no esta instalado"

# Puertos para OLS - distintos a Nginx (80/443) y Apache (8080/8443)
OLS_HTTP_PORT=8088
OLS_HTTPS_PORT=8488
OLS_ADMIN_PORT=7080

log "Iniciando instalacion de OpenLiteSpeed (modo backend, puerto $OLS_HTTP_PORT)..."

# Verificar que los puertos no esten en uso
for PORT in $OLS_HTTP_PORT $OLS_HTTPS_PORT $OLS_ADMIN_PORT; do
    if ss -tlnp 2>/dev/null | grep -q ":$PORT "; then
        error "Puerto $PORT en uso. Libera el puerto antes de continuar."
    fi
done
log "Puertos $OLS_HTTP_PORT, $OLS_HTTPS_PORT, $OLS_ADMIN_PORT disponibles"

# Instalar repositorio OLS
curl -fsSL https://repo.litespeed.sh 2>/dev/null | bash -s -- --lsws 2>/dev/null || {
    warn "Metodo 1 fallido, intentando alternativa..."
    wget -q --timeout=30 -O - \
        http://rpms.litespeedtech.com/debian/enable_lst_debian_repo.sh 2>/dev/null | bash || \
        error "No se pudo configurar el repositorio de OpenLiteSpeed"
}

apt-get update -qq
apt-get install -y -qq openlitespeed 2>/dev/null || \
    error "No se pudo instalar OpenLiteSpeed"

log "OpenLiteSpeed instalado"

# ── PASO CRITICO: Configurar puertos ANTES de iniciar OLS ────────────────────
# OLS por defecto usa 80/443 - hay que cambiarlos ANTES de arrancar
# para evitar conflicto con Nginx de QemuCP

OLS_CONF="/usr/local/lsws/conf/httpd_config.conf"

if [ ! -f "$OLS_CONF" ]; then
    error "No se encontro la configuracion de OLS en $OLS_CONF"
fi

# Hacer backup de la config original
cp "$OLS_CONF" "$OLS_CONF.bak.$(date +%Y%m%d)" 2>/dev/null || true

# Cambiar el listener HTTP de 80 a 8088
# El formato en httpd_config.conf de OLS es: address *:80
python3 << PYEOF
import re

with open('$OLS_CONF', 'r') as f:
    content = f.read()

# Cambiar puerto HTTP 80 -> 8088
content = re.sub(r'address\s+\*:80\b', 'address *:$OLS_HTTP_PORT', content)
content = re.sub(r'address\s+0\.0\.0\.0:80\b', 'address 0.0.0.0:$OLS_HTTP_PORT', content)

# Cambiar puerto HTTPS 443 -> 8488
content = re.sub(r'address\s+\*:443\b', 'address *:$OLS_HTTPS_PORT', content)
content = re.sub(r'address\s+0\.0\.0\.0:443\b', 'address 0.0.0.0:$OLS_HTTPS_PORT', content)

# Cambiar puerto admin 8088 (si ya existe) -> 7080
content = re.sub(r'(adminListener.*?address\s+)\*:8088', r'\g<1>*:$OLS_ADMIN_PORT', content)

# Cambiar usuario a www-data para compatibilidad con QemuCP/HestiaCP
content = re.sub(r'\buser\s+nobody\b', 'user www-data', content)
content = re.sub(r'\bgroup\s+nogroup\b', 'group www-data', content)

with open('$OLS_CONF', 'w') as f:
    f.write(content)

print('OK - puertos OLS configurados')
PYEOF

log "OLS configurado en puertos $OLS_HTTP_PORT (HTTP) y $OLS_HTTPS_PORT (HTTPS)"

# Instalar lsphp para las versiones soportadas
log "Instalando lsphp para PHP 7.4, 8.0, 8.1, 8.2, 8.3..."
PHP_VERSIONS=("83" "82" "81" "80" "74")
for VER in "${PHP_VERSIONS[@]}"; do
    apt-get install -y -qq \
        "lsphp${VER}" \
        "lsphp${VER}-common" \
        "lsphp${VER}-mysql" \
        "lsphp${VER}-opcache" \
        "lsphp${VER}-curl" \
        "lsphp${VER}-imagick" 2>/dev/null || \
        warn "lsphp${VER} no disponible, continuando..."
done
log "lsphp instalado"

# Crear directorios necesarios
mkdir -p /usr/local/lsws/logs/domains
mkdir -p /usr/local/lsws/conf/vhosts
mkdir -p /dev/shm/lscache

# Permisos correctos para compatibilidad con QemuCP
chown -R www-data:www-data /usr/local/lsws/logs 2>/dev/null || \
    chown -R nobody:nogroup /usr/local/lsws/logs 2>/dev/null || true

log "Directorios OLS creados"

# Copiar templates OLS al directorio de QemuCP
OLS_TPL_DST="$HESTIA/data/templates/web/openlitespeed"
OLS_TPL_SRC="$HESTIA/install/deb/templates/web/openlitespeed"

if [ -d "$OLS_TPL_DST" ]; then
    log "Templates OLS ya presentes en QemuCP"
else
    if [ -d "$OLS_TPL_SRC" ]; then
        mkdir -p "$OLS_TPL_DST/php-fpm"
        cp -r "$OLS_TPL_SRC/"* "$OLS_TPL_DST/" 2>/dev/null || true
        log "Templates OLS copiados a QemuCP"
    else
        warn "Templates OLS no encontrados - descargando desde GitHub..."
        mkdir -p "$OLS_TPL_DST/php-fpm"
        BASE="https://raw.githubusercontent.com/qemugen/qemucp/release"
        for f in default.tpl default.stpl php-fpm/default.tpl php-fpm/default.stpl \
                 php-fpm/default.sh php-fpm/wordpress.tpl php-fpm/wordpress.stpl \
                 php-fpm/wordpress.sh php-fpm/prestashop.tpl php-fpm/prestashop.stpl \
                 php-fpm/prestashop.sh; do
            wget -q --timeout=30 \
                "$BASE/install/deb/templates/web/openlitespeed/$f" \
                -O "$OLS_TPL_DST/$f" 2>/dev/null || true
        done
        log "Templates OLS descargados"
    fi
fi

# Registrar OLS en la configuracion de QemuCP
HESTIA_CONF="$HESTIA/conf/hestia.conf"
if ! grep -q "OLS_SYSTEM" "$HESTIA_CONF" 2>/dev/null; then
    echo "" >> "$HESTIA_CONF"
    echo "# QemuCP OpenLiteSpeed" >> "$HESTIA_CONF"
    echo "OLS_SYSTEM='openlitespeed'" >> "$HESTIA_CONF"
    echo "OLS_PORT='$OLS_HTTP_PORT'" >> "$HESTIA_CONF"
    echo "OLS_SSL_PORT='$OLS_HTTPS_PORT'" >> "$HESTIA_CONF"
    log "OLS registrado en configuracion de QemuCP"
fi

# Habilitar e iniciar OLS
systemctl enable lsws 2>/dev/null || true
systemctl start lsws 2>/dev/null || warn "No se pudo iniciar OLS automaticamente"

# Verificar que Nginx sigue corriendo (no debe haberse roto)
if systemctl is-active nginx > /dev/null 2>&1; then
    log "Nginx sigue activo - sin conflictos de puerto"
else
    warn "Nginx no esta activo - verifica con: systemctl status nginx"
fi

# Aplicar traducciones
if [ -f "$HESTIA/install/ols-i18n-patch.sh" ]; then
    bash "$HESTIA/install/ols-i18n-patch.sh" 2>/dev/null || true
fi

log ""
log "OpenLiteSpeed instalado correctamente en modo backend"
log "  Puerto HTTP:   $OLS_HTTP_PORT (distinto a Nginx en 80)"
log "  Puerto HTTPS:  $OLS_HTTPS_PORT (distinto a Nginx en 443)"
log "  Puerto Admin:  $OLS_ADMIN_PORT"
log "  Nginx:         sigue activo en puertos 80/443 sin cambios"
log ""
log "Para usar OLS en un dominio:"
log "  v-change-web-domain-backend USUARIO DOMINIO openlitespeed yes"
log ""
log "Para volver a Apache2:"
log "  v-change-web-domain-backend USUARIO DOMINIO apache2 yes"
