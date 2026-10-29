#!/usr/bin/env bats
# =============================================================================
#  Pruebas de QemuCP sobre una instalacion REAL hecha con
#  install/qemucp_install.sh (las lanza .github/workflows/qemucp-ci.yml).
#
#  Cada prueba corresponde a algo que fallo en produccion o que hemos
#  anadido. Si una falla, el nombre dice que se ha roto.
# =============================================================================

H=/usr/local/hestia
B=$H/bin
export PATH=$B:$PATH

setup_file() {
    # Sufijo propio para que se pueda lanzar dos veces (antes y despues de
    # relanzar el instalador) sin chocar con los usuarios de la pasada anterior.
    export CI_ID="$(date +%s | tail -c 6)"
    echo "$CI_ID" > /tmp/qemucp-ci-id
    U="ciq${CI_ID}"
    "$B/v-add-user" "$U" 'Ci-Pass-2026!x' "ci@qemucp.test" default "CI" >/dev/null
    # Plan como los que se venden: 1 dominio (el principal) y 2 subdominios
    cp "$H/data/packages/default.pkg" "$H/data/packages/ciplan.pkg"
    sed -i "s/^WEB_DOMAINS=.*/WEB_DOMAINS='1'/; s/^WEB_SUBDOMAINS=.*/WEB_SUBDOMAINS='2'/" "$H/data/packages/ciplan.pkg"
    # Usuario SOLO para las pruebas de cupos, sin ningun dominio previo. Antes
    # compartian usuario con la prueba de sesiones, que ya le habia creado un
    # dominio, y el plan de "1 dominio" llegaba lleno.
    "$B/v-add-user" "cis${CI_ID}" 'Ci-Pass-2026!x' "s@qemucp.test" ciplan "CIS" >/dev/null
}

teardown_file() {
    CI_ID="$(cat /tmp/qemucp-ci-id)"
    "$B/v-delete-user" "ciq${CI_ID}" >/dev/null 2>&1 || true
    "$B/v-delete-user" "ciw${CI_ID}" >/dev/null 2>&1 || true
    "$B/v-delete-user" "cis${CI_ID}" >/dev/null 2>&1 || true
    "$B/v-delete-user" "wpq${CI_ID}" >/dev/null 2>&1 || true
    rm -f "$H/data/packages/ciplan.pkg"
}

setup() {
    CI_ID="$(cat /tmp/qemucp-ci-id)"
    U="ciq${CI_ID}"
    S="cis${CI_ID}"
    IP=$(hostname -I | awk '{print $1}')
}

# Intenta crear un dominio web e imprime CREADO / RECHAZADO
crear() {
    rm -rf "/home/$1/web/$2"
    if "$B/v-add-web-domain" "$1" "$2" >/tmp/ci-crear.log 2>&1; then echo CREADO
    else echo "RECHAZADO $(grep -oE '(WEB_SUBDOMAINS|WEB_DOMAINS) limit is reached' /tmp/ci-crear.log | head -1)"; fi
}

# ------------------------------------------------------------- instalacion
@test "el panel se ha instalado desde el fork y esta retenido frente a apt" {
    run grep -q '^fork ' "$H/conf/qemucp-origen"
    [ "$status" -eq 0 ] || { echo "origen: $(cat $H/conf/qemucp-origen 2>/dev/null)"; false; }
    apt-mark showhold | grep -qx hestia
}

@test "la version instalada es la del fork" {
    inst=$(grep '^VERSION=' "$H/conf/hestia.conf" | cut -d"'" -f2)
    fork=$(dpkg-query -W -f='${Version}' hestia | cut -d- -f1)
    echo "hestia.conf=$inst paquete=$fork"
    [ -n "$inst" ] && [ "$inst" = "$fork" ]
}

@test "servicios activos" {
    fallan=""
    for s in nginx apache2 mariadb exim4 dovecot hestia cron redis-server fail2ban; do
        systemctl is-active --quiet "$s" || fallan="$fallan $s"
    done
    systemctl is-active --quiet bind9 || systemctl is-active --quiet named || fallan="$fallan bind9"
    ls /run/php/php*-fpm.pid >/dev/null 2>&1 || systemctl list-units --state=active 'php*-fpm*' | grep -q fpm || fallan="$fallan php-fpm"
    echo "no activos:${fallan:- ninguno}"
    [ -z "$fallan" ]
}

@test "el panel responde en el puerto 8083 con la marca QemuCP" {
    run curl -sk --max-time 20 "https://127.0.0.1:8083/login/"
    [ "$status" -eq 0 ]
    echo "$output" | grep -qi "qemucp"
}

@test "las configuraciones de nginx, apache y php-fpm son validas" {
    nginx -t
    apache2ctl -t
    for d in /etc/php/*/fpm; do
        v=$(basename "$(dirname "$d")")
        "php-fpm$v" -t
    done
}

@test "seguridad PHP (php2shell): actualizaciones automaticas y mitigacion solo bajo peticion" {
    # Por defecto NO se toca session.upload_progress (hay clientes que lo usan)
    ! ls /etc/php/*/fpm/conf.d/99-qemucp-seguridad.ini 2>/dev/null
    if dpkg -l unattended-upgrades | grep -q '^ii'; then
        grep -q "LP-PPA-ondrej-php" /etc/apt/apt.conf.d/52qemucp-php-seguridad
    fi
    run bash "$H/data/qemucp/parche-php.sh" --comprobar
    echo "$output"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q "Estado de PHP"
    # Todas las versiones instaladas con el parche de php2shell
    ! echo "$output" | grep -q "SIN PARCHE"
    # El PHP interno del panel tambien (compilado desde el fork)
    v=$("$H/php/bin/php" -r 'echo PHP_VERSION;'); echo "panel: $v"
    dpkg --compare-versions "$v" ge 8.5.12
}

# --------------------------------------------- plantillas y sesiones (Redis)
@test "plantillas php-fpm: un unico bloque QemuCP y una sola session.save_path" {
    malas=""
    for t in "$H"/data/templates/web/php-fpm/*.tpl; do
        nb=$(grep -c '^; -- QemuCP: Optimizaciones de rendimiento --$' "$t" || true)
        ns=$(grep -c '^php_admin_value\[session.save_path\]' "$t" || true)
        nh=$(grep -c '^php_admin_value\[session.save_handler\]' "$t" || true)
        nf=$(grep -c '^php_admin_value\[session.save_path\] = /home/' "$t" || true)
        [ "$nb" -eq 1 ] && [ "$ns" -eq 1 ] && [ "$nh" -eq 1 ] && [ "$nf" -eq 0 ] || malas="$malas $(basename $t)(bloques=$nb save_path=$ns handler=$nh fichero=$nf)"
    done
    echo "plantillas mal:${malas:- ninguna}"
    [ -z "$malas" ]
}

@test "redis responde" {
    run redis-cli ping
    [ "$output" = "PONG" ]
}

@test "las sesiones PHP de una web se guardan en Redis" {
    D="ses${CI_ID}.qemucp.test"
    "$B/v-add-web-domain" "$U" "$D" >/dev/null
    printf '<?php session_start(); $_SESSION["ci"]=1; echo "SESION_OK ".session_id();' \
        > "/home/$U/web/$D/public_html/index.php"
    chown "$U:$U" "/home/$U/web/$D/public_html/index.php"
    "$B/v-restart-web-backend" yes >/dev/null 2>&1 || true
    "$B/v-restart-web" yes >/dev/null 2>&1 || true
    "$B/v-restart-proxy" yes >/dev/null 2>&1 || true
    sleep 3
    run curl -s --max-time 20 -H "Host: $D" "http://$IP/index.php"
    echo "respuesta: ${output:0:200}"
    echo "$output" | grep -q "SESION_OK"
    sid=$(echo "$output" | grep -oE 'SESION_OK [a-z0-9]+' | awk '{print $2}')
    run redis-cli -n 1 --scan --pattern "SESS_${sid}"
    echo "clave en redis: $output"
    [ -n "$output" ]
}

@test "filtro anti-bots de PrestaShop: ?q= sin cookie da 403 en nginx; con cookie y en otras webs, normal" {
    F=$H/data/qemucp/qemucp-filtro-prestashop.sh
    [ -x "$F" ]
    grep -q "qemucp-filtro-prestashop.sh --todas" /etc/cron.d/qemucp-filtro-prestashop
    PS="tienda${CI_ID}.qemucp.test"; WP="otra${CI_ID}.qemucp.test"
    "$B/v-add-web-domain" "$U" "$PS" >/dev/null
    "$B/v-add-web-domain" "$U" "$WP" >/dev/null
    # Tienda PrestaShop 1.7 de mentira (lo que mira la deteccion)
    mkdir -p "/home/$U/web/$PS/public_html/app/config" "/home/$U/web/$PS/public_html/classes"
    echo "<?php return array();" > "/home/$U/web/$PS/public_html/app/config/parameters.php"
    echo "<?php echo 'TIENDA';" > "/home/$U/web/$PS/public_html/index.php"
    echo "<?php echo 'OTRA';" > "/home/$U/web/$WP/public_html/index.php"
    chown -R "$U:$U" "/home/$U/web/$PS/public_html" "/home/$U/web/$WP/public_html"
    run bash "$F" --todas
    echo "$output"
    [ "$status" -eq 0 ]
    [ -f "/home/$U/conf/web/$PS/nginx.conf_qemucp_filtro_ps" ]
    [ ! -f "/home/$U/conf/web/$WP/nginx.conf_qemucp_filtro_ps" ]
    nginx -t
    c() { curl -s -o /dev/null -w '%{http_code}' --max-time 20 -H "Host: $1" "${@:2}"; }
    sin=$(c "$PS" "http://$IP/?q=Precio-EUR-1-99"); con=$(c "$PS" -H "Cookie: PrestaShop-0123456789abcdef0123456789abcdef=x" "http://$IP/?q=Precio-EUR-1-99")
    normal=$(c "$PS" "http://$IP/"); otra=$(c "$WP" "http://$IP/?q=algo")
    echo "tienda ?q= sin cookie=$sin con cookie=$con sin ?q=$normal | otra web ?q= sin cookie=$otra"
    [ "$sin" = "403" ]; [ "$con" = "200" ]; [ "$normal" = "200" ]; [ "$otra" = "200" ]
    # Se conserva al reconstruir el dominio y se puede quitar
    "$B/v-rebuild-web-domain" "$U" "$PS" yes >/dev/null
    [ "$(c "$PS" "http://$IP/?q=x")" = "403" ]
    bash "$F" --quitar "$PS"
    [ "$(c "$PS" "http://$IP/?q=x")" = "200" ]
}

@test "antispam: listas negras con codigos de listado, exim las acepta y SpamAssassin al dia" {
    grep -q '^zen.spamhaus.org=127.0.0.2' /etc/exim4/dnsbl.conf
    grep -q '^bl.spamcop.net=127.0.0.2' /etc/exim4/dnsbl.conf
    grep -q '^psbl.surriel.com=' /etc/exim4/dnsbl.conf
    exim4 -bV >/dev/null
    # La lista se expande como la usa la ACL
    run exim4 -be '${readfile {/etc/exim4/dnsbl.conf}{:}}'
    echo "$output"
    echo "$output" | grep -q "zen.spamhaus.org=127.0.0.2,.*:bl.spamcop.net=127.0.0.2"
    # Una sesion SMTP de prueba pasa por la ACL de las listas sin error de configuracion
    run bash -c 'printf "EHLO prueba.example\nMAIL FROM:<a@example.com>\nRCPT TO:<postmaster@example.net>\nQUIT\n" | exim4 -bh 192.0.2.10 2>&1'
    echo "${output: -1500}"
    ! echo "$output" | grep -qi "error in\|configuration error\|failed to expand"
    # El servidor sigue resolviendo nombres (con el BIND local o el del proveedor)
    getent hosts debian.org
    # Reglas de SpamAssassin con actualizacion diaria
    systemctl is-enabled spamassassin-maintenance.timer >/dev/null 2>&1 || [ -f /etc/cron.d/qemucp-sa-update ]
}

@test "varias webs con SSL a la vez: nginx sigue validando y recargando (HTTP/3)" {
    for n in 1 2 3; do
        D="ssl${n}${CI_ID}.qemucp.test"
        "$B/v-add-web-domain" "$U" "$D" >/dev/null
        T=$(mktemp -d)
        openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=$D" \
            -keyout "$T/$D.key" -out "$T/$D.crt" >/dev/null 2>&1
        run "$B/v-add-web-domain-ssl" "$U" "$D" "$T"
        echo "ssl $D: $output"
        [ "$status" -eq 0 ]
        rm -rf "$T"
    done
    run nginx -t
    echo "$output"
    [ "$status" -eq 0 ]
    run "$B/v-restart-proxy"
    [ "$status" -eq 0 ]
    # HTTP/3 sigue activo y reuseport aparece una sola vez por IP:443
    grep -q "quic" "/etc/nginx/conf.d/domains/ssl1${CI_ID}.qemucp.test.ssl.conf"
    [ "$( { grep -rhoE "listen +[0-9.]+:443 quic reuseport" /etc/nginx/conf.d/ || true; } | sort | uniq -d | wc -l)" -eq 0 ]
}

# ---------------------------------------------------------------- MariaDB
@test "mariadb aplica las optimizaciones de QemuCP" {
    bp=$(mysql -Nse "SELECT @@innodb_buffer_pool_size")
    echo "innodb_buffer_pool_size=$bp (por defecto 134217728)"
    [ "$bp" != "134217728" ]
    ! grep -rq '^innodb_buffer_pool_instances' /etc/mysql/
}

# ------------------------------------------------------- hook y cola de cron
@test "el hook de post-actualizacion esta en la ruta que ejecuta HestiaCP" {
    [ -x /etc/hestiacp/hooks/post_install.sh ]
    bash -n /etc/hestiacp/hooks/post_install.sh
    grep -q 'QemuCP-BLOQUE-INICIO' /etc/hestiacp/hooks/post_install.sh
    grep -q '/etc/hestiacp/hooks/post_install.sh' /var/lib/dpkg/info/hestia.postinst
    [ ! -e "$H/data/hooks/post_update.sh" ]
}

@test "la cola de reinicios esta operativa (crontab de hestiaweb)" {
    c=/var/spool/cron/crontabs/hestiaweb
    [ "$(stat -c '%U %a' $c)" = "hestiaweb 600" ]
    grep -q 'v-update-sys-queue restart' "$c"
    [ "$(grep -c 'v-' $c)" -ge 10 ]
}

@test "un dominio nuevo resuelve solo, sin guardar la zona a mano" {
    D="dns${CI_ID}.qemucp.test"
    "$B/v-add-dns-domain" "$U" "$D" "$IP" >/dev/null
    # Lo tiene que recargar el cron de la cola (cada 2 minutos)
    for i in $(seq 1 30); do
        r=$(dig +short +time=2 +tries=1 A "$D" @127.0.0.1 2>/dev/null)
        [ -n "$r" ] && break
        sleep 5
    done
    echo "respuesta tras ${i}x5s: '$r'"
    [ -n "$r" ]
}

# ---------------------------------------------------- dominios y subdominios
@test "limite de subdominios: plan de 1 dominio y 2 subdominios" {
    "$B/v-change-user-package" "$S" ciplan >/dev/null
    [ "$(crear $S cis${CI_ID}.test)" = "CREADO" ]
    [ "$(crear $S a.cis${CI_ID}.test)" = "CREADO" ]
    [ "$(crear $S b.cis${CI_ID}.test)" = "CREADO" ]
    r=$(crear $S c.cis${CI_ID}.test); echo "tercer subdominio: $r"
    [ "$r" = "RECHAZADO WEB_SUBDOMAINS limit is reached" ]
    r=$(crear $S otro${CI_ID}.test); echo "segundo dominio: $r"
    [ "$r" = "RECHAZADO WEB_DOMAINS limit is reached" ]
}

@test "el boton del panel (v-add-domain) crea el vhost de un subdominio con el cupo de dominios lleno" {
    sed -i "s/^WEB_SUBDOMAINS=.*/WEB_SUBDOMAINS='5'/" "$H/data/packages/ciplan.pkg"
    "$B/v-change-user-package" "$S" ciplan >/dev/null
    D="panel.cis${CI_ID}.test"
    "$B/v-add-domain" "$S" "$D" >/dev/null 2>&1 || true
    grep -q "DOMAIN='$D'" "$H/data/users/$S/web.conf"
}

@test "los contadores de dominios y subdominios se guardan bien" {
    "$B/v-update-user-counters" "$S"
    run "$B/v-list-user" "$S"
    echo "$output" | grep -iE "web (sub)?domains"
    echo "$output" | grep -qE "WEB DOMAINS: +1/1"
    echo "$output" | grep -qE "WEB SUBDOMAINS: +3/5"
}

@test "un plan que no cubre el uso se rechaza con el mensaje de subdominios" {
    sed -i "s/^WEB_SUBDOMAINS=.*/WEB_SUBDOMAINS='1'/" "$H/data/packages/ciplan.pkg"
    run "$B/v-change-user-package" "$S" ciplan
    echo "$output"
    echo "$output" | grep -q "WEB_SUBDOMAIN usage"
}

@test "un usuario con plan heredado (sin WEB_SUBDOMAINS) se comporta como HestiaCP original" {
    W="ciw${CI_ID}"
    "$B/v-add-user" "$W" 'Ci-Pass-2026!x' "w@qemucp.test" default "CIW" >/dev/null
    sed -i "/^WEB_SUBDOMAINS=/d; s/^WEB_DOMAINS=.*/WEB_DOMAINS='2'/" "$H/data/users/$W/user.conf"
    [ "$(crear $W ciw${CI_ID}.test)" = "CREADO" ]
    [ "$(crear $W a.ciw${CI_ID}.test)" = "CREADO" ]
    r=$(crear $W b.ciw${CI_ID}.test); echo "tercero con cupo conjunto 2/2: $r"
    [ "$r" = "RECHAZADO WEB_DOMAINS limit is reached" ]
}

@test "el JSON de paquetes que lee el panel es valido e incluye WEB_SUBDOMAINS" {
    "$B/v-list-user-packages" json | python3 -c 'import json,sys; d=json.load(sys.stdin); assert all("WEB_SUBDOMAINS" in v for v in d.values())'
}

@test "fail2ban esta activo y con las jaulas de HestiaCP cargadas" {
    systemctl is-active --quiet fail2ban
    n=$(fail2ban-client status | grep -oP 'Number of jail:\s*\K[0-9]+')
    echo "jaulas activas: $n"; fail2ban-client status | grep 'Jail list'
    [ "$n" -ge 5 ]
    fail2ban-client status | grep -q 'ssh-iptables'
    fail2ban-client status | grep -q 'hestia-iptables'
}

@test "nginx.conf no tiene load_module duplicados" {
    d=$(grep '^load_module' /etc/nginx/nginx.conf | sort | uniq -d)
    echo "duplicados: ${d:-ninguno}"
    [ -z "$d" ]
}

# ------------------------------------------------------------------ nginx
@test "nginx carga los modulos GeoIP2 y Brotli" {
    nginx -T 2>/dev/null | grep -qE 'load_module .*geoip2'
    nginx -T 2>/dev/null | grep -qE 'load_module .*brotli'
}

# ------------------------------------------------------------------ tema
@test "el tema qemucp va en el paquete y no se pierde ningun tema de HestiaCP" {
    for t in default dark flat vestia qemucp; do
        echo "tema $t"; [ -s "$H/web/css/themes/$t.min.css" ]
    done
    # Acciones como botones con texto: se muestra el span traducido y se
    # oculta el icono
    grep -q 'units-table-row-action-link>.u-hide-desktop{display:inline!important' "$H/web/css/themes/qemucp.min.css"
    "$B/v-list-sys-themes" plain | grep -qx qemucp
    "$B/v-list-sys-themes" json | python3 -c 'import json,sys; assert "qemucp" in json.load(sys.stdin)'
}

@test "qemucp es el tema por defecto: sistema, admin y usuarios nuevos" {
    grep -qx "THEME='qemucp'" "$H/conf/hestia.conf"
    grep -qx "THEME='qemucp'" "$H/data/users/admin/user.conf"
    # v-add-user deja THEME='' = hereda el del sistema
    grep -qx "THEME=''" "$H/data/users/$U/user.conf"
}

@test "el panel sirve el CSS del tema qemucp" {
    run curl -sk --max-time 20 -o /dev/null -w '%{http_code}' "https://127.0.0.1:8083/css/themes/qemucp.min.css"
    echo "HTTP $output"
    [ "$output" = "200" ]
}

@test "el gestor de archivos carga el CSS de QemuCP (logo blanco visible)" {
    [ -d "$H/web/fm" ] || skip "gestor de archivos no instalado"
    [ -s "$H/web/fm/dist/css/qemucp-fm.css" ] || [ -s "$H/web/fm/css/qemucp-fm.css" ]
    grep -q '/fm/css/qemucp-fm.css' "$H/web/fm/configuration.php"
    # La version servida es la del paquete (incluye el arreglo del modo oscuro)
    cat "$H/web/fm/dist/css/qemucp-fm.css" "$H/web/fm/css/qemucp-fm.css" 2>/dev/null | grep -q "Modo oscuro del sistema"
}

# ------------------------------------------------------- textos sencillos
@test "el selector de PHP se llama 'Version de PHP' y muestra PHP 8.3 en vez de PHP-8_3" {
    for f in edit_web add_package edit_package; do
        echo "plantilla $f"
        grep -q '_("PHP Version")' "$H/web/templates/pages/$f.php"
        ! grep -q '_("Backend Template")' "$H/web/templates/pages/$f.php"
        grep -q 'qemucp_backend_label(' "$H/web/templates/pages/$f.php"
    done
    python3 -c 'import gettext,sys; t=gettext.GNUTranslations(open(sys.argv[1],"rb")); assert t.gettext("PHP Version")=="Versión de PHP"; assert t.gettext("Server default")=="Por defecto del servidor"' \
        "$H/web/locale/es/LC_MESSAGES/hestiacp.mo"
    fn=$(sed -n '/^function qemucp_backend_label/,/^}/p' "$H/web/inc/main.php")
    out=$("$H/php/bin/php" -r "$fn echo qemucp_backend_label('PHP-8_3'), '|', qemucp_backend_label(\"'PHP-7_4'\"), '|', qemucp_backend_label('mi-plantilla');")
    echo "$out"
    [ "$out" = "PHP 8.3|PHP 7.4|mi-plantilla" ]
}

@test "Configuracion del servidor: los lapices llevan el texto 'Editar' para el tema qemucp" {
    n=$(grep -c 'qemucp-edit-link' "$H/web/templates/pages/edit_server.php")
    echo "enlaces: $n"
    [ "$n" -ge 9 ]
    grep -q 'qemucp-edit-link' "$H/web/css/themes/qemucp.min.css"
}

@test "el panel no muestra la marca qemugen (textos, logos ni favicon)" {
    r=$(grep -rIil "qemugen" "$H/web/templates" "$H/web/inc" "$H/web/locale" 2>/dev/null || true)
    echo "con qemugen: ${r:-ninguno}"
    [ -z "$r" ]
    # favicon cuadrado de QemuCP (el de qemugen era un logo apaisado 180x36)
    python3 -c 'import struct,sys; d=open(sys.argv[1],"rb").read(24); w,h=struct.unpack(">II",d[16:24]); assert w==h, (w,h)' "$H/web/images/favicon.png"
    grep -q 'href="/images/favicon.png"' "$H/web/templates/includes/css.php"
}

# ------------------------------------------------------------------ WP-TOOL
@test "WP-TOOL: la pestana APLICACIONES esta en el menu (se perdio en la sync 1.10.3)" {
    grep -q 'href="/list/wp/"' "$H/web/templates/includes/panel.php"
    [ -x "$B/v-qemucp-wp" ]
    for f in list/wp/index.php edit/wp/index.php templates/pages/list_wp.php; do
        echo "fichero $f"; [ -s "$H/web/$f" ]
    done
    # Las acciones llevan token anti-CSRF
    grep -q 'verify_csrf' "$H/web/edit/wp/index.php"
}

@test "WP-TOOL: v-qemucp-wp detecta WordPress, su version y el modo mantenimiento" {
    W="wpq${CI_ID}"; D="wp${CI_ID}.test"
    "$B/v-add-user" "$W" 'Ci-Pass-2026!x' "wp@qemucp.test" default "WPQ" >/dev/null
    [ "$(crear $W $D)" = "CREADO" ]
    R="/home/$W/web/$D/public_html"
    # Sin WordPress: lista vacia y las acciones se niegan
    [ "$("$B/v-qemucp-wp" "$W" list | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" = "0" ]
    run "$B/v-qemucp-wp" "$W" flush-cache "$D"
    [ "$status" -ne 0 ]
    # WordPress de mentira: basta con lo que mira la deteccion
    mkdir -p "$R/wp-includes"
    echo '<?php // config' > "$R/wp-config.php"
    printf "<?php\n\$wp_version = '6.6.2';\n" > "$R/wp-includes/version.php"
    out=$("$B/v-qemucp-wp" "$W" list); echo "$out"
    echo "$out" | python3 -c 'import json,sys; d=json.load(sys.stdin)[sys.argv[1]]; assert d["VERSION"]=="6.6.2" and d["MAINTENANCE"]=="no", d' "$D"
    touch "$R/.maintenance"
    "$B/v-qemucp-wp" "$W" list | python3 -c 'import json,sys; assert json.load(sys.stdin)[sys.argv[1]]["MAINTENANCE"]=="yes"' "$D"
    # Accion desconocida y dominio ajeno: error
    run "$B/v-qemucp-wp" "$W" borrar-todo "$D";  [ "$status" -ne 0 ]
    run "$B/v-qemucp-wp" "$W" update "noexiste.test"; [ "$status" -ne 0 ]
    "$B/v-delete-user" "$W" >/dev/null 2>&1 || true
}

# ------------------------------------------------------- APLICACIONES
@test "instalador de aplicaciones: todos los instaladores cargan (uno roto tumba la lista entera)" {
    [ -f "$H/web/src/vendor/autoload.php" ] || skip "dependencias del instalador no instaladas"
    run "$H/php/bin/php" -r '
        require "/usr/local/hestia/web/src/init.php";
        $mal = 0;
        foreach (glob("/usr/local/hestia/web/src/app/WebApp/Installers/*/*Setup.php") as $f) {
            $d = basename(dirname($f));
            $c = "\\Hestia\\WebApp\\Installers\\$d\\{$d}Setup";
            try { if (!class_exists($c)) { echo "FALTA $d\n"; $mal++; } }
            catch (Throwable $e) { echo "ROTO $d: " . $e->getMessage() . "\n"; $mal++; }
        }
        exit($mal ? 1 : 0);'
    echo "$output"
    [ "$status" -eq 0 ]
    # Las de QemuCP heredan los instaladores oficiales de HestiaCP 1.10
    grep -q 'extends WordPressSetup' "$H/web/src/app/WebApp/Installers/WordPressOptimized/WordPressOptimizedSetup.php"
    grep -q 'extends PrestaShopSetup' "$H/web/src/app/WebApp/Installers/PrestaShopOptimized/PrestaShopOptimizedSetup.php"
    # La lista usa la carpeta (no el nombre visible) para logo e ?app=
    grep -qF '"app" => $app_dir' "$H/web/templates/pages/list_webapps.php"
}

@test "Performance Dashboard: enlace en la barra y sin la comprobacion de \$_SESSION['role']" {
    grep -q 'href="/list/performance/"' "$H/web/templates/includes/panel.php"
    ! grep -q "_SESSION\['role'\]" "$H/web/api/performance-stats/index.php"
    grep -q 'userContext' "$H/web/api/performance-stats/index.php"
    # El controlador carga la sesion antes de mirarla
    a=$(grep -n 'inc/main.php' "$H/web/list/performance/index.php" | head -1 | cut -d: -f1)
    b=$(grep -n 'userContext' "$H/web/list/performance/index.php" | head -1 | cut -d: -f1)
    [ "$a" -lt "$b" ]
}

@test "lista de webs del tema qemucp (desplegable estilo Plesk) y aviso al entrar en un usuario" {
    # Con el tema qemucp el controlador usa su plantilla; los demas temas, la de HestiaCP
    grep -q 'list_web_qemucp' "$H/web/list/web/index.php"
    grep -q 'qemucp_theme_active' "$H/web/inc/main.php"
    ! grep -q 'qemucp_parent' "$H/web/templates/pages/list_web.php"
    grep -q 'qemucp_parent' "$H/web/templates/pages/list_web_qemucp.php"
    grep -q 'qemucp-site-panel' "$H/web/css/themes/qemucp.min.css"
    grep -q 'qemucp-look-banner' "$H/web/templates/includes/panel.php"
    for f in templates/pages/list_web_qemucp.php templates/includes/panel.php list/web/index.php; do
        "$H/php/bin/php" -l "$H/web/$f" >/dev/null
    done
}
