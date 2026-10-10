#!/usr/bin/env bats
# =============================================================================
#  Pruebas del migrador de cPanel (install/migrate/cpanel-import.sh) sobre una
#  instalacion REAL de QemuCP, con un backup de cPanel sintetico que reune los
#  casos que fallaban en produccion (test/fixtures/make-cpanel-backup.sh).
# =============================================================================

H=/usr/local/hestia
B=$H/bin
export PATH=$B:$PATH
U=cpclient
MIG=/hestiacp-git/install/migrate/cpanel-import.sh
BK=/tmp/cpanel-ci/backup-10.9.2026_10-00-00_cpclient.tar.gz
OUT=/tmp/cpanel-ci/importacion.log

setup_file() {
    mkdir -p /tmp/cpanel-ci
    bash /hestiacp-git/test/fixtures/make-cpanel-backup.sh "$BK" >/dev/null
    # Plan pequeno: el migrador debe negarse ANTES de crear nada
    cp "$H/data/packages/default.pkg" "$H/data/packages/cimig.pkg"
    sed -i "s/^WEB_DOMAINS=.*/WEB_DOMAINS='1'/" "$H/data/packages/cimig.pkg"
    # Plan antiguo (sin WEB_SUBDOMAINS): dominios y subdominios juntos
    cp "$H/data/packages/default.pkg" "$H/data/packages/cimigviejo.pkg"
    sed -i "/^WEB_SUBDOMAINS=/d; s/^WEB_DOMAINS=.*/WEB_DOMAINS='5'/" "$H/data/packages/cimigviejo.pkg"
    # Plan JUSTO: 5 dominios y 2 subdominios. Si el migrador contara distinto
    # que QemuCP, aqui fallaria la creacion de algun dominio.
    cp "$H/data/packages/default.pkg" "$H/data/packages/cimigjusto.pkg"
    sed -i "s/^WEB_DOMAINS=.*/WEB_DOMAINS='5'/; s/^WEB_SUBDOMAINS=.*/WEB_SUBDOMAINS='2'/" "$H/data/packages/cimigjusto.pkg"
    set +e
    bash "$MIG" "$BK" cpclient cimig > /tmp/cpanel-ci/plan-corto.log 2>&1
    echo $? > /tmp/cpanel-ci/plan-corto.rc
    bash "$MIG" "$BK" cpclient cimigviejo > /tmp/cpanel-ci/plan-viejo.log 2>&1
    echo $? > /tmp/cpanel-ci/plan-viejo.rc
    bash "$MIG" "$BK" cpclient cimigjusto > "$OUT" 2>&1
    echo $? > /tmp/cpanel-ci/importacion.rc
    set -e
    sleep 3
}

teardown_file() {
    rm -f "$H/data/packages/cimig.pkg" "$H/data/packages/cimigviejo.pkg"
}

ip_srv() { v-list-sys-ips plain | awk '{print $1}' | head -1; }
# IP que llevan los DNS: la publica si el servidor esta tras NAT
ip_dns() { local i n; i=$(ip_srv); n=$(grep -oP "^NAT='\K[^']*" "$H/data/ips/$i" 2>/dev/null || true); echo "${n:-$i}"; }
q() { dig +short +time=2 +tries=2 @127.0.0.1 "$@"; }
web_doms() { v-list-web-domains "$U" plain | cut -f1 | sort | tr '\n' ' '; }
mailval() { grep "^ACCOUNT='$3'" "$H/data/users/$U/mail/$2.conf" | grep -oP "$1='\K[^']*"; }

@test "migrador: un plan que no cubre el backup se rechaza sin crear nada" {
    cat /tmp/cpanel-ci/plan-corto.log | tail -5
    [ "$(cat /tmp/cpanel-ci/plan-corto.rc)" -ne 0 ]
    grep -q "se queda corto" /tmp/cpanel-ci/plan-corto.log
    grep -q "Dominios: el backup necesita 5 y el plan permite 1" /tmp/cpanel-ci/plan-corto.log
}

@test "migrador: plan antiguo (sin limite de subdominios) cuenta todo junto" {
    tail -5 /tmp/cpanel-ci/plan-viejo.log
    [ "$(cat /tmp/cpanel-ci/plan-viejo.rc)" -ne 0 ]
    grep -q "Dominios (incluye subdominios en este plan): el backup necesita 7 y el plan permite 5" /tmp/cpanel-ci/plan-viejo.log
}

@test "migrador: con un plan justo (5 dominios + 2 subdominios) entra todo" {
    grep -q "El plan 'cimigjusto' cubre todo" "$OUT"
    ! grep -q "No se pudo crear el dominio web" "$OUT"
}

@test "migrador: la importacion termina bien" {
    tail -40 "$OUT"
    [ "$(cat /tmp/cpanel-ci/importacion.rc)" -eq 0 ]
    grep -q "IMPORTACION COMPLETADA" "$OUT"
}

@test "migrador: dominios adicionales y subdominios correctos, sin los subdominios internos de cPanel" {
    echo "web: $(web_doms)"
    [ "$(web_doms)" = "adicional-ci.com blog.principal-ci.com otro-ci.org principal-ci.com promo.aparcado-ci.net shop.adicional-ci.com tienda-ci.es " ]
}

@test "migrador: contadores del usuario 5 dominios / 2 subdominios (promo.aparcado cuenta como dominio)" {
    v-update-user-counters "$U"
    run v-list-user "$U" json
    echo "$output" | grep -E 'U_WEB_(SUB)?DOMAINS'
    echo "$output" | grep -q '"U_WEB_DOMAINS": "5"'
    echo "$output" | grep -q '"U_WEB_SUBDOMAINS": "2"'
}

@test "migrador: dominio aparcado como alias del principal (con www)" {
    a=$(v-list-web-domain "$U" principal-ci.com json | grep -oP '"ALIAS": "\K[^"]*')
    echo "alias: $a"
    [[ ",$a," == *",aparcado-ci.net,"* ]]
    [[ ",$a," == *",www.aparcado-ci.net,"* ]]
}

@test "migrador: cada web con sus ficheros y sin duplicar las carpetas de otros dominios" {
    W=/home/$U/web
    grep -q principal "$W/principal-ci.com/public_html/index.php"
    grep -q tienda "$W/tienda-ci.es/public_html/index.php"
    grep -q blog "$W/blog.principal-ci.com/public_html/index.php"
    grep -q adicional "$W/adicional-ci.com/public_html/index.php"
    grep -q shop "$W/shop.adicional-ci.com/public_html/index.php"
    grep -q promo "$W/promo.aparcado-ci.net/public_html/index.php"
    [ ! -e "$W/principal-ci.com/public_html/promo" ]
    [ ! -e "$W/principal-ci.com/public_html/tienda" ]
    [ ! -e "$W/principal-ci.com/public_html/blog" ]
    [ "$(stat -c %U "$W/principal-ci.com/public_html/index.php")" = "$U" ]
}

@test "migrador: resto del home copiado con su ruta (scripts de cron)" {
    [ -x "/home/$U/scripts/backup.sh" ]
    [ "$(stat -c %U /home/$U/scripts/backup.sh)" = "$U" ]
    # QemuCP deja el home como lo necesita la jaula SFTP (root o el usuario);
    # lo que no puede pasar es que el backup le ponga otro dueno.
    o=$(stat -c %U /home/$U); echo "home: $o"
    [ "$o" = "$U" ] || [ "$o" = "root" ]
}

@test "migrador: .htaccess de cPanel adaptado (no descarga los .php, sin error 500)" {
    HT=/home/$U/web/principal-ci.com/public_html/.htaccess
    cat "$HT"
    ! grep -qE '^[[:space:]]*AddHandler application/x-httpd-ea-php' "$HT"
    ! grep -qE '^[[:space:]]*php_(value|flag)' "$HT"
    grep -q "upload_max_filesize = 64M" /home/$U/web/principal-ci.com/public_html/.user.ini
    [ -f "$HT.cpanel-orig" ]
}

@test "migrador: la web principal se sirve (PHP ejecutado, no descargado)" {
    run curl -s --max-time 10 -H "Host: principal-ci.com" "http://$(ip_srv)/index.php"
    echo "$output" | head -5
    [ "$output" = "principal" ] || { tail -20 /var/log/apache2/domains/principal-ci.com.error.log /var/log/apache2/error.log 2>/dev/null; false; }
}

@test "migrador: version de PHP de cPanel asignada" {
    tpl=$(v-list-web-domain "$U" principal-ci.com json | grep -oP '"BACKEND": "\K[^"]+')
    echo "backend: $tpl"
    [ "$tpl" = "PHP-8_1" ]
}

@test "migrador: bases de datos importadas (tambien vistas con DEFINER)" {
    [ "$(mysql -N -e 'SELECT COUNT(*) FROM cpclient_wp.wp_options')" -eq 2 ]
    [ "$(mysql -N -e 'SELECT COUNT(*) FROM cpclient_wp.v_opciones')" -eq 2 ]
    [ "$(mysql -N -e 'SELECT COUNT(*) FROM cpclient_tienda.productos')" -eq 3 ]
}

@test "migrador: wp-config apunta a la base de datos nueva y sus credenciales funcionan" {
    WP=/home/$U/web/principal-ci.com/public_html/wp-config.php
    DBU=$(grep -oP "DB_USER', '\K[^']+" "$WP"); DBP=$(grep -oP "DB_PASSWORD', '\K[^']+" "$WP")
    echo "user=$DBU"
    [ "$DBU" = "cpclient_wp" ]
    mysql -u "$DBU" -p"$DBP" -N -e 'SELECT COUNT(*) FROM cpclient_wp.wp_options'
}

@test "migrador: buzones con su contrasena ORIGINAL de cPanel" {
    doveadm auth test info@principal-ci.com 'ClaveInfo2024!'
    doveadm auth test juan@principal-ci.com 'ClaveJuan2024!'
    doveadm auth test ventas@tienda-ci.es 'ClaveVentas1!'
}

@test "migrador: las contrasenas sobreviven a una reconstruccion del usuario" {
    v-rebuild-user "$U" no >/dev/null
    v-rebuild-mail-domains "$U" no >/dev/null
    doveadm auth test info@principal-ci.com 'ClaveInfo2024!'
    doveadm auth test ventas@tienda-ci.es 'ClaveVentas1!'
}

@test "migrador: cuenta por defecto de cPanel con su correo y su contrasena" {
    doveadm auth test cpclient@principal-ci.com 'ClaveCpanel1!'
    ls /home/$U/mail/principal-ci.com/cpclient/cur | grep -q 9001
    ls /home/$U/mail/principal-ci.com/cpclient/.Sent/cur | grep -q 9002
}

@test "migrador: mensajes y carpetas copiados" {
    ls /home/$U/mail/principal-ci.com/juan/cur | grep -q 2001
    ls /home/$U/mail/principal-ci.com/juan/.Sent/cur | grep -q 2002
    [ "$(stat -c %U:%G /home/$U/mail/principal-ci.com/juan/cur)" = "$U:mail" ]
}

@test "migrador: buzon en formato mdbox convertido a maildir" {
    command -v doveadm >/dev/null || skip "sin doveadm"
    doveadm auth test archivo@principal-ci.com 'ClaveArchivo1!'
    doveadm search -u archivo@principal-ci.com mailbox INBOX ALL | grep -q .
    doveadm search -u archivo@principal-ci.com mailbox Archivados ALL | grep -q .
    [ -d /home/$U/mail/principal-ci.com/archivo/cur ]
    [ ! -d /home/$U/mail/principal-ci.com/archivo/storage ]
}

@test "migrador: cuota del buzon" {
    [ "$(mailval QUOTA principal-ci.com info)" = "500" ]
}

@test "migrador: reenviador puro (sin buzon) solo reenvia" {
    f=$(mailval FWD principal-ci.com ventas)
    echo "ventas FWD=$f FWD_ONLY=$(mailval FWD_ONLY principal-ci.com ventas)"
    [[ ",$f," == *",juan@principal-ci.com,"* ]]
    [[ ",$f," == *",externo-ci@example.org,"* ]]
    [ "$(mailval FWD_ONLY principal-ci.com ventas)" = "yes" ]
}

@test "migrador: reenvio en cuenta con buzon guarda copia" {
    [ "$(mailval FWD principal-ci.com info)" = "copia-ci@example.org" ]
    [ "$(mailval FWD_ONLY principal-ci.com info)" != "yes" ]
}

@test "migrador: catch-all a la cuenta por defecto" {
    c=$(v-list-mail-domain "$U" principal-ci.com json | grep -oP '"CATCHALL": "\K[^"]*')
    echo "catchall=$c"
    [ "$c" = "cpclient@principal-ci.com" ]
}

@test "migrador: reenvio de dominio (aparcado-ci.net -> principal-ci.com)" {
    [ "$(mailval FWD aparcado-ci.net info)" = "info@principal-ci.com" ]
    [ "$(mailval FWD aparcado-ci.net juan)" = "juan@principal-ci.com" ]
}

@test "migrador: correo externo (Google) no se crea en local; MX del hosting viejo si" {
    ! v-list-mail-domain "$U" adicional-ci.com >/dev/null 2>&1
    v-list-mail-domain "$U" tienda-ci.es >/dev/null
}

@test "migrador: DNS principal - zona valida, web y correo a este servidor" {
    named-checkzone principal-ci.com /home/$U/conf/dns/principal-ci.com.db
    [ "$(q principal-ci.com A)" = "$(ip_dns)" ]
    [ "$(q principal-ci.com MX)" = "0 mail.principal-ci.com." ]
    [ "$(q mail.principal-ci.com A)" = "$(ip_dns)" ]
    [ "$(q blog.principal-ci.com A)" = "$(ip_dns)" ]
    [ "$(q sinttl.principal-ci.com A)" = "$(ip_dns)" ]
    [ -z "$(q principal-ci.com AAAA)" ]
}

@test "migrador: DNS principal - registros externos intactos" {
    [ "$(q crm.principal-ci.com A)" = "203.0.113.50" ]
    [ "$(q _sip._tcp.principal-ci.com SRV)" = "10 60 5060 sip.proveedor-ci.com." ]
    q principal-ci.com TXT | grep -q "google-site-verification=abc123"
}

@test "migrador: DNS principal - un solo SPF, con lo del cliente y sin el servidor viejo" {
    q principal-ci.com TXT
    [ "$(q principal-ci.com TXT | grep -c v=spf1)" -eq 1 ]
    q principal-ci.com TXT | grep v=spf1 | grep -q "include:sendgrid.net"
    q principal-ci.com TXT | grep v=spf1 | grep -q "ip4:$(ip_dns)"
    ! q principal-ci.com TXT | grep -q "198.51.100.10"
}

@test "migrador: DNS principal - un solo DMARC (el del cliente) y DKIM de este servidor" {
    [ "$(q _dmarc.principal-ci.com TXT | grep -c DMARC1)" -eq 1 ]
    q _dmarc.principal-ci.com TXT | grep -q "p=none"
    q mail._domainkey.principal-ci.com TXT | grep -q "v=DKIM1"
    [ -z "$(q default._domainkey.principal-ci.com TXT)" ]
}

@test "migrador: DNS principal - sin registros de cPanel y CAA con Let's Encrypt" {
    for n in cpanel whm webdisk cpcalendars autodiscover _cpanel-dcv-test-record; do
        [ -z "$(q $n.principal-ci.com ANY | grep -v '^$')" ] || { echo "sobra $n"; false; }
    done
    q principal-ci.com CAA | grep -q letsencrypt.org
}

@test "migrador: DNS con correo externo - MX y SPF de Google, nada local" {
    q adicional-ci.com MX
    q adicional-ci.com MX | grep -q "aspmx.l.google.com."
    ! q adicional-ci.com MX | grep -q "mail.adicional-ci.com"
    [ "$(q adicional-ci.com TXT | grep -c v=spf1)" -eq 1 ]
    q adicional-ci.com TXT | grep -q "include:_spf.google.com"
    [ -z "$(q _dmarc.adicional-ci.com TXT)" ]
    [ -z "$(q _imap._tcp.adicional-ci.com SRV)" ]
    [ "$(q shop.adicional-ci.com A)" = "$(ip_dns)" ]
}

@test "migrador: MX dentro del dominio pero en otro servidor = correo externo, intacto" {
    q otro-ci.org MX
    [ "$(q otro-ci.org MX)" = "10 mail.otro-ci.org." ]
    [ "$(q mail.otro-ci.org A)" = "192.0.2.25" ]
    [ "$(q webmail.otro-ci.org CNAME)" = "correo.proveedor-ci.com." ]
    ! v-list-mail-domain "$U" otro-ci.org >/dev/null 2>&1
    [ "$(q otro-ci.org TXT | grep -c v=spf1)" -eq 0 ]
    [ -z "$(q _imap._tcp.otro-ci.org SRV)" ]
    [ "$(q otro-ci.org A)" = "$(ip_dns)" ]
    grep -q otro /home/$U/web/otro-ci.org/public_html/index.php
}

@test "migrador: DNS con MX al hostname del hosting viejo pasa a correo local" {
    [ "$(q tienda-ci.es MX)" = "0 mail.tienda-ci.es." ]
}

@test "migrador: crons con las rutas y el PHP de QemuCP" {
    v-list-cron-jobs "$U" plain
    C="$H/data/users/$U/cron.conf"
    [ "$(wc -l < "$C")" -eq 4 ]
    grep -q "/home/$U/web/principal-ci.com/public_html/wp-cron.php" "$C"
    grep -q "/home/$U/web/tienda-ci.es/public_html/cron.php" "$C"
    grep -q "/home/$U/web/adicional-ci.com/public_html/tarea.php" "$C"
    grep -q "CMD='/home/$U/scripts/backup.sh'" "$C"
    ! grep -q "public_html/tienda/" "$C"
    ! grep -q "/usr/local/bin/php\|/opt/cpanel" "$C"
    grep "backup.sh" "$C" | grep -q "MIN='0' HOUR='0' DAY='\*'"
    grep "tarea.php" "$C" | grep -q "WDAY='1'"
}

@test "migrador: SSL vigente de cPanel instalado" {
    [ "$(v-list-web-domain "$U" principal-ci.com json | grep -oP '"SSL": "\K[^"]+')" = "yes" ]
}

@test "migrador: informe con lo que hay que revisar a mano" {
    I=$(ls -t /root/qemucp-import-cpclient-*.txt | head -1)
    cat "$I"
    grep -q "pipe@principal-ci.com" "$I"
    grep -q "@reboot" "$I"
    grep -q "adicional-ci.com tiene 1 buzones" "$I"
    grep -q "nopass@principal-ci.com" "$I"
}

@test "migrador: volver a ejecutarlo no duplica nada" {
    R1=$(wc -l < "$H/data/users/$U/dns/principal-ci.com.conf")
    C1=$(wc -l < "$H/data/users/$U/cron.conf")
    run bash "$MIG" "$BK"
    echo "$output" | tail -20
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$H/data/users/$U/dns/principal-ci.com.conf")" -eq "$R1" ]
    [ "$(wc -l < "$H/data/users/$U/cron.conf")" -eq "$C1" ]
    [ "$(web_doms)" = "adicional-ci.com blog.principal-ci.com otro-ci.org principal-ci.com promo.aparcado-ci.net shop.adicional-ci.com tienda-ci.es " ]
    doveadm auth test info@principal-ci.com 'ClaveInfo2024!'
}

@test "migrador: no mezcla clientes si el usuario ya existe y es de otro" {
    v-add-user ajenoci 'Clave-Ajeno-123' ajeno@example.org default >/dev/null
    run bash "$MIG" "$BK" ajenoci
    echo "$output" | tail -5
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "parece otro cliente"
    [ -z "$(v-list-web-domains ajenoci plain)" ]
    v-delete-user ajenoci >/dev/null
}

@test "migrador: se para si los dominios ya estan en otra cuenta" {
    run bash "$MIG" "$BK" nuevoci
    echo "$output" | tail -8
    [ "$status" -ne 0 ]
    echo "$output" | grep -q "principal-ci.com (cuenta cpclient)"
    ! v-list-user nuevoci >/dev/null 2>&1
}

@test "migrador en lote: sigue tras un fallo y deja resumen" {
    L=/tmp/cpanel-ci/lista.txt
    printf '%s - cimigjusto\n/tmp/cpanel-ci/no-existe.tar.gz\n' "$BK" > "$L"
    run bash /hestiacp-git/install/migrate/cpanel-import-lote.sh "$L"
    echo "$output" | tail -15
    [ "$status" -ne 0 ]
    R=$(ls -td /root/qemucp-lote-* | head -1)/RESUMEN.txt
    grep -q "OK .*backup-10.9.2026_10-00-00_cpclient .*usuario cpclient" "$R"
    grep -q "FALLO .*no-existe" "$R"
    grep -q "Correctas: 1   Fallidas: 1" "$R"
}
