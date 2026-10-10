#!/bin/bash
# Genera un backup de cPanel sintetico (formato pkgacct) con todos los casos
# que el migrador tiene que resolver bien. Lo usa test/cpanel-import.bats.
#
#   bash make-cpanel-backup.sh /ruta/salida.tar.gz
#
# Cuenta 'cpclient' en un servidor de origen con IP 198.51.100.10:
#   principal-ci.com      dominio principal (public_html), correo local
#   adicional-ci.com      dominio adicional (carpeta ~/adicional-ci.com),
#                         correo en Google (externo)
#   tienda-ci.es          dominio adicional DENTRO de public_html/tienda,
#                         MX al hostname del hosting viejo (correo local)
#   blog.principal-ci.com subdominio del principal
#   shop.adicional-ci.com subdominio de un dominio adicional
#   otro-ci.org           dominio adicional cuyo MX es mail.otro-ci.org pero
#                         ese nombre apunta a OTRO servidor (correo externo)
#   aparcado-ci.net       dominio aparcado + reenvio de dominio a principal
#   promo.aparcado-ci.net subdominio de un dominio aparcado (en QemuCP gasta
#                         un dominio: el aparcado es solo un alias)
# Mas: reenviadores, catch-all, cuenta por defecto, contrasenas, cuotas,
# crons con rutas y PHP de cPanel, bases de datos con DEFINER, wp-config,
# .htaccess de MultiPHP, zonas con basura de cPanel, SSL vigente.
set -euo pipefail

OUT="${1:?Uso: make-cpanel-backup.sh salida.tar.gz}"
U=cpclient
ORIGIN=198.51.100.10
TMP=$(mktemp -d)
B="$TMP/backup-10.9.2026_10-00-00_$U"
H="$B/homedir"
mkdir -p "$B"/{cp,userdata,dnszones,va,vad,vf,mysql,cron,apache_tls} "$H"

# ---- cp/ ----------------------------------------------------------------
cat > "$B/cp/$U" << EOF
BWLIMIT=unlimited
CONTACTEMAIL=cliente-ci@example.org
DNS=principal-ci.com
DNS1=adicional-ci.com
DNS2=tienda-ci.es
DNS3=aparcado-ci.net
DNS4=otro-ci.org
IP=$ORIGIN
PLAN=default
USER=$U
EOF

# Contrasena de la cuenta cPanel (la usa la cuenta de correo por defecto)
openssl passwd -6 'ClaveCpanel1!' > "$B/shadow"

# ---- userdata/ ----------------------------------------------------------
cat > "$B/userdata/main" << 'EOF'
---
addon_domains:
  adicional-ci.com: adicional-ci.principal-ci.com
  tienda-ci.es: tienda.principal-ci.com
  otro-ci.org: otro-ci.principal-ci.com
cp_php_magic_include_path.conf: 0
main_domain: principal-ci.com
parked_domains:
  - aparcado-ci.net
sub_domains:
  - adicional-ci.principal-ci.com
  - otro-ci.principal-ci.com
  - blog.principal-ci.com
  - promo.aparcado-ci.net
  - shop.adicional-ci.com
  - tienda.principal-ci.com
EOF
ud() {  # nombre docroot alias phpversion
    cat > "$B/userdata/$1" << EOF
---
documentroot: $2
group: $U
hascgi: 1
homedir: /home/$U
ip: $ORIGIN
owner: root
phpopenbasedirprotect: 1
${4:+phpversion: $4}
port: 80
serveradmin: webmaster@$1
serveralias: $3
servername: $1
usecanonicalname: 'Off'
user: $U
EOF
}
ud principal-ci.com "/home/$U/public_html" "aparcado-ci.net www.aparcado-ci.net www.principal-ci.com" ea-php81
ud adicional-ci.principal-ci.com "/home/$U/adicional-ci.com" "adicional-ci.com www.adicional-ci.com www.adicional-ci.principal-ci.com" ea-php82
ud tienda.principal-ci.com "/home/$U/public_html/tienda" "tienda-ci.es www.tienda-ci.es www.tienda.principal-ci.com"
ud otro-ci.principal-ci.com "/home/$U/otro-ci.org" "otro-ci.org www.otro-ci.org www.otro-ci.principal-ci.com"
ud blog.principal-ci.com "/home/$U/public_html/blog" "www.blog.principal-ci.com"
ud promo.aparcado-ci.net "/home/$U/public_html/promo" "www.promo.aparcado-ci.net"
ud shop.adicional-ci.com "/home/$U/shop.adicional-ci.com" "www.shop.adicional-ci.com"
# Ficheros que NO son dominios (antes acababan como alias)
echo "---" > "$B/userdata/principal-ci.com.php-fpm.yaml"
echo "---" > "$B/userdata/principal-ci.com_SSL"
echo "{}" > "$B/userdata/cache.json"

# ---- Ficheros web -------------------------------------------------------
mkdir -p "$H/public_html/tienda" "$H/public_html/blog" "$H/public_html/promo" "$H/adicional-ci.com" \
         "$H/shop.adicional-ci.com" "$H/scripts" "$H/public_html/wp-content"
echo '<?php echo "principal"; ?>' > "$H/public_html/index.php"
echo '<?php echo "tienda"; ?>'    > "$H/public_html/tienda/index.php"
echo '<?php echo "blog"; ?>'      > "$H/public_html/blog/index.php"
echo '<?php echo "promo"; ?>'     > "$H/public_html/promo/index.php"
echo '<?php echo "adicional"; ?>' > "$H/adicional-ci.com/index.php"
echo '<?php echo "shop"; ?>'      > "$H/shop.adicional-ci.com/index.php"
mkdir -p "$H/otro-ci.org"
echo '<?php echo "otro"; ?>'      > "$H/otro-ci.org/index.php"
printf '#!/bin/bash\necho copia\n' > "$H/scripts/backup.sh"
chmod 755 "$H/scripts/backup.sh"
cat > "$H/public_html/.htaccess" << 'EOF'
RewriteEngine On
php_value upload_max_filesize 64M
php_flag display_errors Off

# php -- BEGIN cPanel-generated handler, do not edit
# Set the "ea-php81" package as the default "PHP" programming language.
<IfModule mime_module>
  AddHandler application/x-httpd-ea-php81 .php .php8 .phtml
</IfModule>
# php -- END cPanel-generated handler, do not edit
EOF
cat > "$H/public_html/wp-config.php" << 'EOF'
<?php
define( 'DB_NAME', 'cpclient_wp' );
define( 'DB_USER', 'cpclient_wpuser' );
define( 'DB_PASSWORD', 'viejaclave' );
define( 'DB_HOST', 'localhost' );
$table_prefix = 'wp_';
EOF

# ---- Bases de datos -----------------------------------------------------
cat > "$B/mysql/cpclient_wp.sql" << 'EOF'
CREATE TABLE `wp_options` (`option_id` int NOT NULL, `option_name` varchar(64), `option_value` text, PRIMARY KEY (`option_id`));
INSERT INTO `wp_options` VALUES (1,'siteurl','https://principal-ci.com'),(2,'blogname','CI');
/*!50001 CREATE ALGORITHM=UNDEFINED */
/*!50013 DEFINER=`cpclient_wpuser`@`localhost` SQL SECURITY DEFINER */
/*!50001 VIEW `v_opciones` AS select `option_name` from `wp_options` */;
EOF
cat << 'EOF' | gzip > "$B/mysql/cpclient_tienda.sql.gz"
CREATE TABLE `productos` (`id` int NOT NULL, `nombre` varchar(64), PRIMARY KEY (`id`));
INSERT INTO `productos` VALUES (1,'uno'),(2,'dos'),(3,'tres');
EOF
echo "-- grants" > "$B/mysql.sql"

# ---- Correo -------------------------------------------------------------
msg() {  # carpeta id
    mkdir -p "$1"/{cur,new,tmp}
    printf 'From: a@example.org\nTo: b@example.org\nSubject: prueba %s\n\nhola\n' "$2" > "$1/cur/$2.host:2,S"
}
# principal-ci.com (local)
mkdir -p "$H/etc/principal-ci.com"
printf 'info:x:1001:1001::/home/%s/mail/principal-ci.com/info:/home/%s\njuan:x:1001:1001::/home/%s/mail/principal-ci.com/juan:/home/%s\nnopass:x:1001:1001::/home/%s/mail/principal-ci.com/nopass:/home/%s\n' \
    $U $U $U $U $U $U > "$H/etc/principal-ci.com/passwd"
printf 'info:%s:19000::::::\njuan:%s:19000::::::\n' \
    "$(openssl passwd -6 'ClaveInfo2024!')" "$(openssl passwd -6 'ClaveJuan2024!')" > "$H/etc/principal-ci.com/shadow"
printf 'info:524288000\njuan:0\n' > "$H/etc/principal-ci.com/quota"
msg "$H/mail/principal-ci.com/info" 1001
msg "$H/mail/principal-ci.com/juan" 2001
msg "$H/mail/principal-ci.com/juan/.Sent" 2002
# cuenta por defecto (cpclient@principal-ci.com): mail/{cur,new,tmp}
msg "$H/mail" 9001
msg "$H/mail/.Sent" 9002
# tienda-ci.es (local por el MX del hosting viejo)
mkdir -p "$H/etc/tienda-ci.es"
printf 'ventas:x:1001:1001::/home/%s/mail/tienda-ci.es/ventas:/home/%s\n' $U $U > "$H/etc/tienda-ci.es/passwd"
printf 'ventas:%s:19000::::::\n' "$(openssl passwd -6 'ClaveVentas1!')" > "$H/etc/tienda-ci.es/shadow"
msg "$H/mail/tienda-ci.es/ventas" 3001
# adicional-ci.com (correo en Google: NO debe importarse)
mkdir -p "$H/etc/adicional-ci.com"
printf 'pepe:x:1001:1001::/home/%s/mail/adicional-ci.com/pepe:/home/%s\n' $U $U > "$H/etc/adicional-ci.com/passwd"
msg "$H/mail/adicional-ci.com/pepe" 4001

# Reenviadores (valiases) y reenvio de dominio (vdomainaliases)
cat > "$B/va/principal-ci.com" << 'EOF'
ventas@principal-ci.com: juan@principal-ci.com,externo-ci@example.org
info@principal-ci.com: copia-ci@example.org
pipe@principal-ci.com: "|/home/cpclient/script.php"
*: cpclient
EOF
echo '*: :fail: No Such User Here' > "$B/va/tienda-ci.es"
echo '*: :fail: No Such User Here' > "$B/va/adicional-ci.com"
echo 'principal-ci.com' > "$B/vad/aparcado-ci.net"
: > "$B/vf/principal-ci.com"

# ---- Cron ---------------------------------------------------------------
cat > "$B/cron/$U" << 'EOF'
MAILTO="cliente-ci@example.org"
SHELL="/bin/bash"
*/15 * * * * /usr/local/bin/php /home/cpclient/public_html/wp-cron.php >/dev/null 2>&1
0 3 * * * /opt/cpanel/ea-php81/root/usr/bin/php /home/cpclient/public_html/tienda/cron.php
@daily /home/cpclient/scripts/backup.sh
30 2 * * mon /usr/bin/php /home/cpclient/adicional-ci.com/tarea.php
@reboot /home/cpclient/start.sh
EOF

# ---- Zonas DNS ----------------------------------------------------------
cat > "$B/dnszones/principal-ci.com.db" << EOF
; cPanel first:11.110.0.0 (update_time):1700000000
\$TTL 14400
principal-ci.com.	86400	IN	SOA	ns1.hostingviejo.com.	admin.hostingviejo.com.	(
		2024010101	;Serial Number
		3600	;refresh
		1800	;retry
		1209600	;expire
		86400	)
principal-ci.com.	86400	IN	NS	ns1.hostingviejo.com.
principal-ci.com.	86400	IN	NS	ns2.hostingviejo.com.
principal-ci.com.	14400	IN	A	$ORIGIN
principal-ci.com.	14400	IN	AAAA	2001:db8::10
principal-ci.com.	14400	IN	MX	0	principal-ci.com.
mail	14400	IN	CNAME	principal-ci.com.
www	14400	IN	CNAME	principal-ci.com.
ftp	14400	IN	A	$ORIGIN
blog	14400	IN	A	$ORIGIN
crm	14400	IN	A	203.0.113.50
cpanel	14400	IN	A	$ORIGIN
whm	14400	IN	A	$ORIGIN
webdisk	14400	IN	A	$ORIGIN
webmail	14400	IN	A	$ORIGIN
cpcalendars	14400	IN	A	$ORIGIN
autodiscover	14400	IN	A	$ORIGIN
_cpanel-dcv-test-record	300	IN	TXT	"_cpanel-dcv-test-record=abc"
default._domainkey	14400	IN	TXT	"v=DKIM1\; k=rsa\; p=MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAviejo"
principal-ci.com.	14400	IN	TXT	"v=spf1 +a +mx +ip4:$ORIGIN include:sendgrid.net ~all"
principal-ci.com.	14400	IN	TXT	"google-site-verification=abc123"
_dmarc	14400	IN	TXT	"v=DMARC1\; p=none\; rua=mailto:dmarc-ci@example.org"
principal-ci.com.	14400	IN	CAA	0 issue "sectigo.com"
_sip._tcp	14400	IN	SRV	10 60 5060 sip.proveedor-ci.com.
sinttl	IN	A	$ORIGIN
EOF
cat > "$B/dnszones/adicional-ci.com.db" << EOF
\$TTL 14400
@	86400	IN	SOA	ns1.hostingviejo.com. admin.hostingviejo.com. ( 2024010101 3600 1800 1209600 86400 )
@	86400	IN	NS	ns1.hostingviejo.com.
@	86400	IN	NS	ns2.hostingviejo.com.
@	14400	IN	A	$ORIGIN
www	14400	IN	CNAME	adicional-ci.com.
shop	14400	IN	A	$ORIGIN
@	3600	IN	MX	1	aspmx.l.google.com.
@	3600	IN	MX	5	alt1.aspmx.l.google.com.
@	14400	IN	TXT	"v=spf1 include:_spf.google.com ~all"
EOF
cat > "$B/dnszones/tienda-ci.es.db" << EOF
\$TTL 14400
tienda-ci.es.	86400	IN	SOA	ns1.hostingviejo.com. admin.hostingviejo.com. 2024010101 3600 1800 1209600 86400
tienda-ci.es.	86400	IN	NS	ns1.hostingviejo.com.
tienda-ci.es.	86400	IN	NS	ns2.hostingviejo.com.
tienda-ci.es.	14400	IN	A	$ORIGIN
tienda-ci.es.	14400	IN	MX	10	server7.hostingviejo.com.
www	14400	IN	CNAME	tienda-ci.es.
EOF
cat > "$B/dnszones/aparcado-ci.net.db" << EOF
\$TTL 14400
aparcado-ci.net.	86400	IN	SOA	ns1.hostingviejo.com. admin.hostingviejo.com. 2024010101 3600 1800 1209600 86400
aparcado-ci.net.	86400	IN	NS	ns1.hostingviejo.com.
aparcado-ci.net.	14400	IN	A	$ORIGIN
aparcado-ci.net.	14400	IN	MX	0	aparcado-ci.net.
promo	14400	IN	A	$ORIGIN
www	14400	IN	CNAME	aparcado-ci.net.
EOF

cat > "$B/dnszones/otro-ci.org.db" << EOF
\$TTL 14400
otro-ci.org.	86400	IN	SOA	ns1.hostingviejo.com. admin.hostingviejo.com. 2024010101 3600 1800 1209600 86400
otro-ci.org.	86400	IN	NS	ns1.hostingviejo.com.
otro-ci.org.	14400	IN	A	$ORIGIN
otro-ci.org.	14400	IN	MX	10	mail.otro-ci.org.
mail	14400	IN	A	192.0.2.25
webmail	14400	IN	CNAME	correo.proveedor-ci.com.
www	14400	IN	CNAME	otro-ci.org.
EOF

# ---- SSL vigente (autofirmado para la prueba) ---------------------------
openssl req -x509 -newkey rsa:2048 -nodes -days 90 -subj "/CN=principal-ci.com" \
    -addext "subjectAltName=DNS:principal-ci.com,DNS:www.principal-ci.com" \
    -keyout "$TMP/k.pem" -out "$TMP/c.pem" 2>/dev/null
cat "$TMP/k.pem" "$TMP/c.pem" > "$B/apache_tls/principal-ci.com"

tar -czf "$OUT" -C "$TMP" "$(basename "$B")"
rm -rf "$TMP"
echo "$OUT"
