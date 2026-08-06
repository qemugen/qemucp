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
FORK="https://raw.githubusercontent.com/qemugen/qemucp/release"
CB="?cb=$(date +%s)"

echo "Reaplicando personalizaciones QemuCP (modo seguro)..."

# --- 1. APP_NAME (seguro, solo config) ---
sed -i "s|APP_NAME=.*|APP_NAME='QemuCP Control Panel'|" "$HESTIA/conf/hestia.conf"

# --- 2. Logos (seguro, son imagenes independientes de la version) ---
curl -s "$FORK/web/images/logo.svg$CB"        -o "$HESTIA/web/images/logo.svg"
curl -s "$FORK/web/images/logo.png$CB"        -o "$HESTIA/web/images/logo.png"
curl -s "$FORK/web/images/logo-header.svg$CB" -o "$HESTIA/web/images/logo-header.svg"

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
FORK_VER=$(curl -s "$FORK/install/hst-install-ubuntu.sh$CB" | grep "HESTIA_INSTALL_VER=" | head -1 | cut -d"'" -f2)

if [ -n "$INSTALLED_VER" ] && [ "$INSTALLED_VER" = "$FORK_VER" ]; then
    # Versiones coinciden: seguro sobrescribir panel.php con WP-TOOL+Performance
    curl -s "$FORK/web/templates/includes/panel.php$CB" -o "$PANEL"
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
curl -s "$FORK/web/list/wp/index.php$CB"          -o "$HESTIA/web/list/wp/index.php"
curl -s "$FORK/web/edit/wp/index.php$CB"          -o "$HESTIA/web/edit/wp/index.php"
curl -s "$FORK/web/templates/pages/list_wp.php$CB" -o "$HESTIA/web/templates/pages/list_wp.php"

# --- 7. Performance Dashboard (ficheros propios) ---
mkdir -p "$HESTIA/web/list/performance" "$HESTIA/web/api/performance-stats"
curl -s "$FORK/web/list/performance/index.php$CB"          -o "$HESTIA/web/list/performance/index.php"
curl -s "$FORK/web/templates/pages/list_performance.php$CB" -o "$HESTIA/web/templates/pages/list_performance.php"
curl -s "$FORK/web/api/performance-stats/index.php$CB"      -o "$HESTIA/web/api/performance-stats/index.php"

# --- 8. Instaladores optimizados (ficheros propios) ---
mkdir -p "$HESTIA/web/src/app/WebApp/Installers/WordPressOptimized" \
         "$HESTIA/web/src/app/WebApp/Installers/PrestaShopOptimized"
curl -s "$FORK/web/src/app/WebApp/Installers/WordPressOptimized/WordPressOptimizedSetup.php$CB" \
    -o "$HESTIA/web/src/app/WebApp/Installers/WordPressOptimized/WordPressOptimizedSetup.php"
curl -s "$FORK/web/src/app/WebApp/Installers/PrestaShopOptimized/PrestaShopOptimizedSetup.php$CB" \
    -o "$HESTIA/web/src/app/WebApp/Installers/PrestaShopOptimized/PrestaShopOptimizedSetup.php"

# --- Limpiar sesiones para refrescar APP_NAME y reiniciar ---
rm -f "$HESTIA/data/sessions/sess_"* 2>/dev/null || true
systemctl restart hestia

echo "OK - Personalizaciones QemuCP reaplicadas (sin tocar login/sesion)."
echo "Cierra sesion y vuelve a entrar (o Ctrl+F5)."
