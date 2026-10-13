#!/bin/bash
# ============================================================
# QemuCP - Re-branding SEGURO ante cualquier version de HestiaCP
# Uso: bash qemucp-rebrand.sh
#
# IMPORTANTE: NO sobrescribe panel.php, login/*.php, main.php ni
# list/user (sensibles a la version de HestiaCP - romperian el login
# si la version del fork no coincide con la instalada). En su lugar,
# PARCHEA in situ solo el logo/nombre sobre los ficheros existentes.
# ============================================================
HESTIA="/usr/local/hestia"
# Descarga RUTA (relativa al repo) en DEST: primero de la copia local del
# fork (/opt/qemucp-src); si no, de GitHub con el token de solo lectura de
# /root/.config/qemucp/github-token (repositorio privado). El token va por la
# entrada estandar de curl (-K -), no como argumento: no sale en ps.
qemucp_bajar() {
    local ruta="$1" dest="$2" tok=""
    if [ -f "/opt/qemucp-src/$ruta" ]; then
        cp -f "/opt/qemucp-src/$ruta" "$dest"
        return
    fi
    tok=$(tr -d '[:space:]' 2>/dev/null < /root/.config/qemucp/github-token || true)
    { [ -n "$tok" ] && printf 'header = "Authorization: token %s"\n' "$tok"; true; } \
        | curl -fsSL --max-time 60 -K - "https://raw.githubusercontent.com/qemugen/qemucp/release/$ruta?cb=$(date +%s)" -o "$dest"
}

echo "Reaplicando personalizaciones QemuCP (modo seguro)..."

# --- 1. APP_NAME (seguro, solo config) ---
sed -i "s|APP_NAME=.*|APP_NAME='QemuCP Control Panel'|" "$HESTIA/conf/hestia.conf"

# --- 2. Logos (seguro, son imagenes independientes de la version) ---
qemucp_bajar "web/images/logo.svg" "$HESTIA/web/images/logo.svg"
qemucp_bajar "web/images/logo.png" "$HESTIA/web/images/logo.png"
qemucp_bajar "web/images/logo-header.svg" "$HESTIA/web/images/logo-header.svg"

# --- 3. Paginas de login: PARCHEAR in situ (NO sobrescribir) ---
# Solo ajustamos las dimensiones del logo para el logo horizontal QemuCP,
# sin tocar la estructura ni la logica de sesion (userContext).
for f in login login_1 login_2 login_a reset_1 reset_2 reset_3 reset2fa; do
    LFILE="$HESTIA/web/templates/pages/login/${f}.php"
    [ -f "$LFILE" ] || continue
    # Ajustar dimensiones del logo (cualquiera que sean -> 280x60 responsive)
    sed -i 's|width="100" height="120"|width="280" height="60" style="max-width:100%;height:auto;"|g' "$LFILE"
    sed -i 's|width="320" height="68"|width="280" height="60" style="max-width:100%;height:auto;"|g' "$LFILE"
done

# --- 4. Panel: sobrescribir SOLO si la version del fork coincide ---
# panel.php es sensible a la version. Solo lo reemplazamos por el del fork
# si la version instalada coincide con la del fork; si no, lo dejamos intacto
# (el panel funciona sin WP-TOOL/Performance pero el login NO se rompe).
PANEL="$HESTIA/web/templates/includes/panel.php"
INSTALLED_VER=$(grep "^VERSION=" "$HESTIA/conf/hestia.conf" | cut -d"'" -f2)
FORK_VER=$(qemucp_bajar install/hst-install-ubuntu.sh /tmp/qemucp-hst-ubuntu.sh 2>/dev/null \
    && grep "HESTIA_INSTALL_VER=" /tmp/qemucp-hst-ubuntu.sh | head -1 | cut -d"'" -f2)
rm -f /tmp/qemucp-hst-ubuntu.sh

if [ -n "$INSTALLED_VER" ] && [ "$INSTALLED_VER" = "$FORK_VER" ]; then
    # Versiones coinciden: seguro sobrescribir panel.php con WP-TOOL+Performance
    qemucp_bajar "web/templates/includes/panel.php" "$PANEL"
    echo "  Panel actualizado con WP-TOOL + Performance (v$INSTALLED_VER)"
else
    echo "  AVISO: version instalada ($INSTALLED_VER) != fork ($FORK_VER)"
    echo "  panel.php NO se toca para no romper el login."
    echo "  WP-TOOL/Performance no apareceran hasta sincronizar el fork a $INSTALLED_VER"
fi

# --- 5. list_services: PARCHEAR el texto (NO sobrescribir) ---
LSVC="$HESTIA/web/templates/pages/list_services.php"
if [ -f "$LSVC" ]; then
    sed -i 's|Hestia Control Panel|QemuCP Control Panel|g' "$LSVC"
fi

# --- 6. WP-TOOL (ficheros propios, no sensibles a version) ---
mkdir -p "$HESTIA/web/list/wp" "$HESTIA/web/edit/wp"
qemucp_bajar "web/list/wp/index.php" "$HESTIA/web/list/wp/index.php"
qemucp_bajar "web/edit/wp/index.php" "$HESTIA/web/edit/wp/index.php"
qemucp_bajar "web/templates/pages/list_wp.php" "$HESTIA/web/templates/pages/list_wp.php"
# Las acciones las ejecuta este comando como root (el panel corre como
# hestiaweb y solo puede lanzar bin/v-*)
qemucp_bajar "bin/v-qemucp-wp" "$HESTIA/bin/v-qemucp-wp" && chmod 755 "$HESTIA/bin/v-qemucp-wp"

# --- 7. Performance Dashboard (ficheros propios) ---
mkdir -p "$HESTIA/web/list/performance" "$HESTIA/web/api/performance-stats"
qemucp_bajar "web/list/performance/index.php" "$HESTIA/web/list/performance/index.php"
qemucp_bajar "web/templates/pages/list_performance.php" "$HESTIA/web/templates/pages/list_performance.php"
qemucp_bajar "web/api/performance-stats/index.php" "$HESTIA/web/api/performance-stats/index.php"

# --- 8. Instaladores optimizados (ficheros propios) ---
mkdir -p "$HESTIA/web/src/app/WebApp/Installers/WordPressOptimized" \
         "$HESTIA/web/src/app/WebApp/Installers/PrestaShopOptimized"
qemucp_bajar "web/src/app/WebApp/Installers/WordPressOptimized/WordPressOptimizedSetup.php" \
    "$HESTIA/web/src/app/WebApp/Installers/WordPressOptimized/WordPressOptimizedSetup.php"
qemucp_bajar "web/src/app/WebApp/Installers/PrestaShopOptimized/PrestaShopOptimizedSetup.php" \
    "$HESTIA/web/src/app/WebApp/Installers/PrestaShopOptimized/PrestaShopOptimizedSetup.php"

# --- Limpiar sesiones para refrescar APP_NAME y reiniciar ---
rm -f "$HESTIA/data/sessions/sess_"* 2>/dev/null || true
systemctl restart hestia

echo "OK - Personalizaciones QemuCP reaplicadas (sin tocar login/sesion)."
echo "Cierra sesion y vuelve a entrar (o Ctrl+F5)."
