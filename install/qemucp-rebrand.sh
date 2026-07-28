#!/bin/bash
# ============================================================
# QemuCP - Re-branding: reaplica personalizaciones tras update
# Uso: bash qemucp-rebrand.sh
# ============================================================
HESTIA="/usr/local/hestia"
FORK="https://raw.githubusercontent.com/qemugen/qemucp/release"
CB="?cb=$(date +%s)"

echo "Reaplicando personalizaciones QemuCP..."

# 1. APP_NAME
sed -i "s|APP_NAME=.*|APP_NAME='QemuCP Control Panel'|" "$HESTIA/conf/hestia.conf"

# 2. Logos
curl -s "$FORK/web/images/logo.svg$CB"        -o "$HESTIA/web/images/logo.svg"
curl -s "$FORK/web/images/logo.png$CB"        -o "$HESTIA/web/images/logo.png"
curl -s "$FORK/web/images/logo-header.svg$CB" -o "$HESTIA/web/images/logo-header.svg"

# 3. Panel con pestaa WP-TOOL
curl -s "$FORK/web/templates/includes/panel.php$CB" -o "$HESTIA/web/templates/includes/panel.php"

# 4. list_services (texto QemuCP Control Panel)
curl -s "$FORK/web/templates/pages/list_services.php$CB" -o "$HESTIA/web/templates/pages/list_services.php"

# 5. Paginas de login con logo QemuCP
for f in login login_1 login_2 login_a reset_1 reset_2 reset_3 reset2fa; do
    curl -s "$FORK/web/templates/pages/login/${f}.php$CB" -o "$HESTIA/web/templates/pages/login/${f}.php"
done

# 6. WP-TOOL
mkdir -p "$HESTIA/web/list/wp" "$HESTIA/web/edit/wp"
curl -s "$FORK/web/list/wp/index.php$CB"          -o "$HESTIA/web/list/wp/index.php"
curl -s "$FORK/web/edit/wp/index.php$CB"          -o "$HESTIA/web/edit/wp/index.php"
curl -s "$FORK/web/templates/pages/list_wp.php$CB" -o "$HESTIA/web/templates/pages/list_wp.php"

# 7. Instaladores optimizados
mkdir -p "$HESTIA/web/src/app/WebApp/Installers/WordPressOptimized" \
         "$HESTIA/web/src/app/WebApp/Installers/PrestaShopOptimized"
curl -s "$FORK/web/src/app/WebApp/Installers/WordPressOptimized/WordPressOptimizedSetup.php$CB" \
    -o "$HESTIA/web/src/app/WebApp/Installers/WordPressOptimized/WordPressOptimizedSetup.php"
curl -s "$FORK/web/src/app/WebApp/Installers/PrestaShopOptimized/PrestaShopOptimizedSetup.php$CB" \
    -o "$HESTIA/web/src/app/WebApp/Installers/PrestaShopOptimized/PrestaShopOptimizedSetup.php"

# 8. Performance Dashboard
mkdir -p "$HESTIA/web/list/performance" "$HESTIA/web/api/performance-stats"
curl -s "$FORK/web/list/performance/index.php$CB"          -o "$HESTIA/web/list/performance/index.php"
curl -s "$FORK/web/templates/pages/list_performance.php$CB" -o "$HESTIA/web/templates/pages/list_performance.php"
curl -s "$FORK/web/api/performance-stats/index.php$CB"      -o "$HESTIA/web/api/performance-stats/index.php"

# Reiniciar panel
systemctl restart hestia

echo "OK - Personalizaciones QemuCP reaplicadas."
echo "Recarga el panel con Ctrl+F5"
