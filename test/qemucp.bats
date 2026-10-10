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
