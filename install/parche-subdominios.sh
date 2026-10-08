#!/bin/bash
# ============================================================================
#  QemuCP - Limite de SUBDOMINIOS separado del de dominios (estilo cPanel)
#
#  Problema que resuelve:
#    HestiaCP cuenta CUALQUIER dominio web en WEB_DOMAINS. Un subdominio
#    (tienda.cliente.com) gasta el mismo cupo que un dominio adicional
#    (otrocliente.es), asi que no se pueden hacer planes con 0 dominios
#    adicionales y N subdominios como en cPanel (maxaddon / maxsub).
#
#  Que hace:
#    Anade la clave WEB_SUBDOMAINS a los paquetes. Un dominio nuevo cuenta
#    contra WEB_SUBDOMAINS si es X.DOMINIO de un dominio que YA aloja el
#    mismo usuario; contra WEB_DOMAINS en cualquier otro caso.
#
#  Compatibilidad:
#    El cambio es por paquete. Mientras un paquete no tenga WEB_SUBDOMAINS
#    con valor, sus usuarios se comportan EXACTAMENTE como ahora. Ningun
#    cliente gana ni pierde cupo hasta que tu edites su paquete.
#
#  Uso:
#    bash parche-subdominios.sh                 aplica el parche
#    bash parche-subdominios.sh --revertir      deshace desde el backup
#
#  Despues de aplicarlo, para cada paquete que quieras pasar al esquema
#  cPanel (ejemplo: 1 dominio, 10 subdominios):
#    v-change-user-package ... no hace falta, se hace desde el panel:
#    Paquetes -> editar -> "Web Domains" = 1 y "Web Subdomains" = 10
#    y guardar (el panel propaga el paquete a sus usuarios).
#  O por SSH:
#    sed -i "/^WEB_DOMAINS=/a WEB_SUBDOMAINS='10'" /usr/local/hestia/data/packages/PLAN.pkg
#    v-update-user-package PLAN
# ============================================================================

set -u
HESTIA="${HESTIA:-/usr/local/hestia}"
BACKUP="/root/qemucp-subdominios-backup-$(date +%Y%m%d-%H%M%S)"
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}OK${NC}   $1"; }
bad()  { echo -e "  ${RED}ERROR${NC} $1"; }
warn() { echo -e "  ${YELLOW}AVISO${NC} $1"; }

FICHEROS="func/main.sh bin/v-add-web-domain bin/v-change-user-package \
bin/v-update-user-counters web/add/package/index.php web/edit/package/index.php \
web/templates/pages/add_package.php web/templates/pages/edit_package.php"

# ---------------------------------------------------------------- revertir
if [ "${1:-}" = "--revertir" ]; then
    # El PRIMER backup es el unico que contiene los ficheros sin parchear.
    # Si se cogiera el ultimo se restauraria una version ya parcheada.
    PRIMERO=$(ls -1d /root/qemucp-subdominios-backup-* 2>/dev/null | head -1)
    [ -z "$PRIMERO" ] && { bad "No hay backup que restaurar"; exit 1; }
    if grep -q "count_web_domains_split" "$PRIMERO/func/main.sh" 2>/dev/null; then
        bad "El backup $PRIMERO ya contiene el parche: no serviria para revertir."
        bad "Restaura func/main.sh, bin/v-add-web-domain, bin/v-change-user-package,"
        bad "bin/v-update-user-counters y los 4 ficheros de web/ desde el paquete"
        bad "oficial: apt-get install --reinstall hestia"
        exit 1
    fi
    echo "Restaurando desde $PRIMERO"
    for F in $FICHEROS; do
        [ -f "$PRIMERO/$F" ] && cp -a "$PRIMERO/$F" "$HESTIA/$F" && ok "$F"
    done
    find "$HESTIA/bin" "$HESTIA/func" "$HESTIA/web" \
        \( -name "*.rej" -o -name "*.orig" \) -delete 2>/dev/null
    systemctl restart hestia 2>/dev/null
    echo "Revertido."
    exit 0
fi

# ---------------------------------------------------------- comprobaciones
echo "============================================================"
echo " Parche: limite de subdominios separado"
echo " Instalacion: $HESTIA"
echo "============================================================"
echo ""
echo "--- Comprobaciones previas ---"

[ -d "$HESTIA/bin" ] || { bad "No parece una instalacion de HestiaCP/QemuCP en $HESTIA"; exit 1; }
command -v patch >/dev/null || { bad "Falta el comando 'patch'. Instalalo: apt install -y patch"; exit 1; }

FALTA=0
for F in $FICHEROS; do
    [ -f "$HESTIA/$F" ] || { bad "no existe $HESTIA/$F"; FALTA=1; }
done
[ "$FALTA" -ne 0 ] && { bad "Instalacion inesperada, no se aplica nada"; exit 1; }
ok "Los 8 ficheros a modificar estan presentes"

# Si ya esta aplicado se sale ANTES de hacer backup. De lo contrario el backup
# guardaria los ficheros ya parcheados y --revertir dejaria de servir.
YA_APLICADO="no"
if grep -q "count_web_domains_split" "$HESTIA/func/main.sh" 2>/dev/null; then
    ok "El parche ya estaba aplicado en esta instalacion"
    YA_APLICADO="si"
fi

# ------------------------------------------------------------------ backup
if [ "$YA_APLICADO" = "si" ]; then
    echo ""
    echo "--- No se reaplica (ya estaba) ---"
fi
if [ "$YA_APLICADO" = "no" ]; then
echo ""
echo "--- Backup ---"
for F in $FICHEROS; do
    mkdir -p "$BACKUP/$(dirname "$F")"
    cp -a "$HESTIA/$F" "$BACKUP/$F"
done
ok "Copia de seguridad en $BACKUP"

# ------------------------------------------------------------------ aplicar
echo ""
echo "--- Aplicando ---"
PATCHFILE=$(mktemp /tmp/qemucp-sub.XXXXXX.patch)
cat > "$PATCHFILE" <<'FIN_DEL_PARCHE'
diff --git a/bin/v-add-web-domain b/bin/v-add-web-domain
index e50498658..80129fc15 100755
--- a/bin/v-add-web-domain
+++ b/bin/v-add-web-domain
@@ -53,7 +53,32 @@ check_args '2' "$#" 'USER DOMAIN [IP] [RESTART] [ALIASES] [PROXY_EXTENSIONS]'
 is_format_valid 'user' 'domain' 'aliases' 'ip' 'proxy_ext' 'restart'
 is_object_valid 'user' 'USER' "$user"
 is_object_unsuspended 'user' 'USER' "$user"
-is_package_full 'WEB_DOMAINS'
+
+# QemuCP: en cPanel un subdominio de un dominio que ya aloja la cuenta no gasta
+# cupo de "addon domains", sino el suyo propio. Si el paquete define
+# WEB_SUBDOMAINS se replica ese comportamiento: el dominio nuevo se contabiliza
+# contra WEB_SUBDOMAINS cuando es X.DOMINIO de un dominio ya alojado por este
+# mismo usuario, y contra WEB_DOMAINS en cualquier otro caso. Si el paquete no
+# define WEB_SUBDOMAINS todo cuenta en WEB_DOMAINS, como en HestiaCP original.
+if has_split_subdomain_limit; then
+	is_new_sub='no'
+	for _parent in $(grep -o "DOMAIN='[^']*'" "$USER_DATA/web.conf" 2> /dev/null | cut -f 2 -d \'); do
+		[ "$domain" = "$_parent" ] && continue
+		case "$domain" in
+			*".$_parent")
+				is_new_sub='yes'
+				break
+				;;
+		esac
+	done
+	if [ "$is_new_sub" = 'yes' ]; then
+		is_package_full 'WEB_SUBDOMAINS'
+	else
+		is_package_full 'WEB_DOMAINS'
+	fi
+else
+	is_package_full 'WEB_DOMAINS'
+fi
 
 if [ "$aliases" != "none" ]; then
 	ALIAS="$aliases"
diff --git a/bin/v-change-user-package b/bin/v-change-user-package
index b05acc641..3194328af 100755
--- a/bin/v-change-user-package
+++ b/bin/v-change-user-package
@@ -33,15 +33,34 @@ is_package_available() {
 	DNS_DOMAINS='0'
 	DISK_QUOTA='0'
 	BANDWIDTH='0'
+	WEB_SUBDOMAINS=''
 
 	source_conf "$HESTIA/data/packages/$package.pkg"
 
+	# QemuCP: si el paquete destino separa subdominios, el uso actual hay que
+	# compararlo tambien separado. Los contadores U_WEB_* del usuario pueden
+	# venir todavia del esquema antiguo (U_WEB_DOMAINS = total), asi que se
+	# recalculan aqui sobre web.conf en lugar de confiar en ellos.
+	if [ -n "$WEB_SUBDOMAINS" ]; then
+		_split=$(count_web_domains_split "$USER_DATA/web.conf")
+		_used_top=$(echo "$_split" | cut -f 1 -d \ )
+		_used_sub=$(echo "$_split" | cut -f 2 -d \ )
+	else
+		_used_top="$U_WEB_DOMAINS"
+		_used_sub=0
+	fi
+
 	# Checking usage agains package limits
 	if [ "$WEB_DOMAINS" != 'unlimited' ]; then
-		if [ "$WEB_DOMAINS" -lt "$U_WEB_DOMAINS" ]; then
+		if [ "$WEB_DOMAINS" -lt "$_used_top" ]; then
 			check_result "$E_LIMIT" "Package doesn't cover WEB_DOMAIN usage"
 		fi
 	fi
+	if [ -n "$WEB_SUBDOMAINS" ] && [ "$WEB_SUBDOMAINS" != 'unlimited' ]; then
+		if [ "$WEB_SUBDOMAINS" -lt "$_used_sub" ]; then
+			check_result "$E_LIMIT" "Package doesn't cover WEB_SUBDOMAIN usage"
+		fi
+	fi
 	if [ "$DNS_DOMAINS" != 'unlimited' ]; then
 		if [ "$DNS_DOMAINS" -lt "$U_DNS_DOMAINS" ]; then
 			check_result "$E_LIMIT" "Package doesn't cover DNS_DOMAIN usage"
@@ -87,6 +106,7 @@ BACKEND_TEMPLATE='$BACKEND_TEMPLATE'
 PROXY_TEMPLATE='$PROXY_TEMPLATE'
 DNS_TEMPLATE='$DNS_TEMPLATE'
 WEB_DOMAINS='$WEB_DOMAINS'
+WEB_SUBDOMAINS='$WEB_SUBDOMAINS'
 WEB_ALIASES='$WEB_ALIASES'
 DNS_DOMAINS='$DNS_DOMAINS'
 DNS_RECORDS='$DNS_RECORDS'
@@ -130,6 +150,7 @@ U_DISK_MAIL='$U_DISK_MAIL'
 U_DISK_DB='$U_DISK_DB'
 U_BANDWIDTH='$U_BANDWIDTH'
 U_WEB_DOMAINS='$U_WEB_DOMAINS'
+U_WEB_SUBDOMAINS='$U_WEB_SUBDOMAINS'
 U_WEB_SSL='$U_WEB_SSL'
 U_WEB_ALIASES='$U_WEB_ALIASES'
 U_DNS_DOMAINS='$U_DNS_DOMAINS'
diff --git a/bin/v-update-user-counters b/bin/v-update-user-counters
index 586f8aa1c..6ee372d15 100755
--- a/bin/v-update-user-counters
+++ b/bin/v-update-user-counters
@@ -67,6 +67,7 @@ for user in $user_list; do
 	BANDWIDTH=0
 	U_BANDWIDTH=0
 	U_WEB_DOMAINS=0
+	U_WEB_SUBDOMAINS=0
 	U_WEB_SSL=0
 	U_WEB_ALIASES=0
 	U_DNS_DOMAINS=0
@@ -106,6 +107,7 @@ for user in $user_list; do
 
 	# Checking web system
 	U_WEB_DOMAINS=0
+	U_WEB_SUBDOMAINS=0
 	if [ -f $USER_DATA/web.conf ]; then
 		for domain_str in $(cat $USER_DATA/web.conf); do
 			parse_object_kv_list "$domain_str"
@@ -125,6 +127,13 @@ for user in $user_list; do
 			BANDWIDTH=$((BANDWIDTH + U_BANDWIDTH))
 		done
 		DISK=$((DISK + U_DISK_WEB))
+		# QemuCP: si el paquete separa subdominios (WEB_SUBDOMAINS), los
+		# contadores deben separarse igual que los limites, para que el panel
+		# muestre "usados/limite" coherente en ambas filas.
+		if has_split_subdomain_limit; then
+			U_WEB_DOMAINS=$(count_web_domains_split "$USER_DATA/web.conf" | cut -f 1 -d \ )
+			U_WEB_SUBDOMAINS=$(count_web_domains_split "$USER_DATA/web.conf" | cut -f 2 -d \ )
+		fi
 	fi
 
 	# Checking dns system
diff --git a/func/main.sh b/func/main.sh
index 8b59d2e26..90bbbab7b 100644
--- a/func/main.sh
+++ b/func/main.sh
@@ -267,10 +267,57 @@ is_system_enabled() {
 	fi
 }
 
+# QemuCP: cuenta los dominios web del usuario separando dominios de nivel
+# superior (lo que cPanel llama "addon domains") de los subdominios de otro
+# dominio del MISMO usuario (lo que cPanel llama "subdomains").
+# Imprime "<dominios> <subdominios>".
+count_web_domains_split() {
+	local _conf="$1"
+	local _doms _d _p _top=0 _sub=0 _is_sub
+	[ -f "$_conf" ] || { echo "0 0"; return; }
+	_doms=$(grep -o "DOMAIN='[^']*'" "$_conf" | cut -f 2 -d \')
+	for _d in $_doms; do
+		_is_sub=0
+		for _p in $_doms; do
+			[ "$_d" = "$_p" ] && continue
+			case "$_d" in
+				*".$_p")
+					_is_sub=1
+					break
+					;;
+			esac
+		done
+		if [ "$_is_sub" -eq 1 ]; then
+			_sub=$((_sub + 1))
+		else
+			_top=$((_top + 1))
+		fi
+	done
+	echo "$_top $_sub"
+}
+
+# QemuCP: cierto si el paquete del usuario define WEB_SUBDOMAINS, es decir si
+# los subdominios tienen su propio limite como en cPanel. Si la clave no existe
+# (paquetes anteriores a este parche) se conserva el comportamiento historico:
+# WEB_DOMAINS cuenta dominios Y subdominios juntos.
+has_split_subdomain_limit() {
+	local _v
+	_v=$(grep -m 1 "^WEB_SUBDOMAINS=" "$USER_DATA/user.conf" 2> /dev/null | cut -f 2 -d \')
+	# Clave ausente o vacia = esquema antiguo (todo cuenta en WEB_DOMAINS).
+	[ -n "$_v" ]
+}
+
 # User package check
 is_package_full() {
 	case "$1" in
-		WEB_DOMAINS) used=$(wc -l $USER_DATA/web.conf) ;;
+		WEB_DOMAINS)
+			if has_split_subdomain_limit; then
+				used=$(count_web_domains_split "$USER_DATA/web.conf" | cut -f 1 -d \ )
+			else
+				used=$(wc -l $USER_DATA/web.conf)
+			fi
+			;;
+		WEB_SUBDOMAINS) used=$(count_web_domains_split "$USER_DATA/web.conf" | cut -f 2 -d \ ) ;;
 		WEB_ALIASES) used=$(echo $aliases | tr ',' '\n' | wc -l) ;;
 		DNS_DOMAINS) used=$(wc -l $USER_DATA/dns.conf) ;;
 		DNS_RECORDS) used=$(wc -l $USER_DATA/dns/$domain.conf) ;;
@@ -281,6 +328,10 @@ is_package_full() {
 	esac
 	used=$(echo "$used" | cut -f 1 -d \ )
 	limit=$(grep "^$1=" $USER_DATA/user.conf | cut -f 2 -d \')
+	# QemuCP: una clave ausente en user.conf equivale a 'unlimited'. Sin esto,
+	# un limite vacio se evalua como 0 en la comparacion aritmetica y bloquea
+	# la creacion en los usuarios cuyo paquete aun no tiene la clave nueva.
+	[ -z "$limit" ] && limit='unlimited'
 	if [ "$1" = WEB_ALIASES ]; then
 		# Used is always calculated with the new alias added
 		if [ "$limit" != 'unlimited' ] && [[ "$used" -gt "$limit" ]]; then
diff --git a/web/add/package/index.php b/web/add/package/index.php
index 32d5e2507..808f7ac40 100644
--- a/web/add/package/index.php
+++ b/web/add/package/index.php
@@ -50,6 +50,9 @@ if (!empty($_POST["ok"])) {
 	if (!isset($_POST["v_web_domains"])) {
 		$errors[] = _("Web Domains");
 	}
+	if (!isset($_POST["v_web_subdomains"])) {
+		$errors[] = _("Web Subdomains");
+	}
 	if (!isset($_POST["v_web_aliases"])) {
 		$errors[] = _("Web Aliases");
 	}
@@ -129,6 +132,7 @@ if (!empty($_POST["ok"])) {
 		$v_dns_template = quoteshellarg($_POST["v_dns_template"]);
 		$v_shell = quoteshellarg($_POST["v_shell"]);
 		$v_web_domains = quoteshellarg($_POST["v_web_domains"]);
+		$v_web_subdomains = quoteshellarg($_POST["v_web_subdomains"]);
 		$v_web_aliases = quoteshellarg($_POST["v_web_aliases"]);
 		$v_dns_domains = quoteshellarg($_POST["v_dns_domains"]);
 		$v_dns_records = quoteshellarg($_POST["v_dns_records"]);
@@ -196,6 +200,7 @@ if (!empty($_POST["ok"])) {
 			}
 			$pkg .= "DNS_TEMPLATE=" . $v_dns_template . "\n";
 			$pkg .= "WEB_DOMAINS=" . $v_web_domains . "\n";
+			$pkg .= "WEB_SUBDOMAINS=" . $v_web_subdomains . "\n";
 			$pkg .= "WEB_ALIASES=" . $v_web_aliases . "\n";
 			$pkg .= "DNS_DOMAINS=" . $v_dns_domains . "\n";
 			$pkg .= "DNS_RECORDS=" . $v_dns_records . "\n";
@@ -297,6 +302,9 @@ if (empty($v_shell)) {
 if (empty($v_web_domains)) {
 	$v_web_domains = "'1'";
 }
+if (empty($v_web_subdomains)) {
+	$v_web_subdomains = "'unlimited'";
+}
 if (empty($v_web_aliases)) {
 	$v_web_aliases = "'5'";
 }
diff --git a/web/edit/package/index.php b/web/edit/package/index.php
index 6085f5e9d..23dc220d8 100644
--- a/web/edit/package/index.php
+++ b/web/edit/package/index.php
@@ -40,6 +40,7 @@ $v_backend_template = $data[$v_package]["BACKEND_TEMPLATE"];
 $v_proxy_template = $data[$v_package]["PROXY_TEMPLATE"];
 $v_dns_template = $data[$v_package]["DNS_TEMPLATE"];
 $v_web_domains = $data[$v_package]["WEB_DOMAINS"];
+$v_web_subdomains = $data[$v_package]["WEB_SUBDOMAINS"] ?? "unlimited";
 $v_web_aliases = $data[$v_package]["WEB_ALIASES"];
 $v_dns_domains = $data[$v_package]["DNS_DOMAINS"];
 $v_dns_records = $data[$v_package]["DNS_RECORDS"];
@@ -163,6 +164,9 @@ if (!empty($_POST["save"])) {
 	if (!isset($_POST["v_web_domains"])) {
 		$errors[] = _("Web Domains");
 	}
+	if (!isset($_POST["v_web_subdomains"])) {
+		$errors[] = _("Web Subdomains");
+	}
 	if (!isset($_POST["v_web_aliases"])) {
 		$errors[] = _("Web Aliases");
 	}
@@ -253,6 +257,7 @@ if (!empty($_POST["save"])) {
 		$v_shell = "nologin";
 	}
 	$v_web_domains = quoteshellarg($_POST["v_web_domains"]);
+	$v_web_subdomains = quoteshellarg($_POST["v_web_subdomains"]);
 	$v_web_aliases = quoteshellarg($_POST["v_web_aliases"]);
 	$v_dns_domains = quoteshellarg($_POST["v_dns_domains"]);
 	$v_dns_records = quoteshellarg($_POST["v_dns_records"]);
@@ -312,6 +317,7 @@ if (!empty($_POST["save"])) {
 	$pkg .= "PROXY_TEMPLATE=" . $v_proxy_template . "\n";
 	$pkg .= "DNS_TEMPLATE=" . $v_dns_template . "\n";
 	$pkg .= "WEB_DOMAINS=" . $v_web_domains . "\n";
+	$pkg .= "WEB_SUBDOMAINS=" . $v_web_subdomains . "\n";
 	$pkg .= "WEB_ALIASES=" . $v_web_aliases . "\n";
 	$pkg .= "DNS_DOMAINS=" . $v_dns_domains . "\n";
 	$pkg .= "DNS_RECORDS=" . $v_dns_records . "\n";
diff --git a/web/templates/pages/add_package.php b/web/templates/pages/add_package.php
index 111df452d..128728d93 100644
--- a/web/templates/pages/add_package.php
+++ b/web/templates/pages/add_package.php
@@ -81,6 +81,17 @@
 							</button>
 						</div>
 					</div>
+					<div class="u-mb10">
+						<label for="v_web_subdomains" class="form-label">
+							<?= tohtml( _("Web Subdomains")) ?> <span class="optional">(<?= tohtml( _("subdomains of own domains")) ?>)</span>
+						</label>
+						<div class="u-pos-relative">
+							<input type="text" class="form-control" name="v_web_subdomains" id="v_web_subdomains" value="<?= tohtml(trim($v_web_subdomains, "'")) ?>">
+							<button type="button" class="unlimited-toggle js-unlimited-toggle" title="<?= tohtml( _("Unlimited")) ?>">
+								<i class="fas fa-infinity"></i>
+							</button>
+						</div>
+					</div>
 					<div class="u-mb10">
 						<label for="v_web_aliases" class="form-label">
 							<?= tohtml( _("Web Aliases")) ?> <span class="optional">(<?= tohtml( _("per domain")) ?>)</span>
diff --git a/web/templates/pages/edit_package.php b/web/templates/pages/edit_package.php
index 0272fd99b..768bed787 100644
--- a/web/templates/pages/edit_package.php
+++ b/web/templates/pages/edit_package.php
@@ -83,6 +83,17 @@
 							</button>
 						</div>
 					</div>
+					<div class="u-mb10">
+						<label for="v_web_subdomains" class="form-label">
+							<?= tohtml( _("Web Subdomains")) ?> <span class="optional">(<?= tohtml( _("subdomains of own domains")) ?>)</span>
+						</label>
+						<div class="u-pos-relative">
+							<input type="text" class="form-control" name="v_web_subdomains" id="v_web_subdomains" value="<?= tohtml(trim($v_web_subdomains, "'")) ?>">
+							<button type="button" class="unlimited-toggle js-unlimited-toggle" title="<?= tohtml( _("Unlimited")) ?>">
+								<i class="fas fa-infinity"></i>
+							</button>
+						</div>
+					</div>
 					<div class="u-mb10">
 						<label for="v_web_aliases" class="form-label">
 							<?= tohtml( _("Web Aliases")) ?> <span class="optional">(<?= tohtml( _("per domain")) ?>)</span>
FIN_DEL_PARCHE

cd "$HESTIA" || exit 1
SALIDA=$(patch -p1 --forward -F3 --no-backup-if-mismatch -r - < "$PATCHFILE" 2>&1)
RES=$?
echo "$SALIDA" | sed 's/^/  /'
rm -f "$PATCHFILE"
# -r - descarta los .rej; por si alguna version de patch los deja igualmente:
find "$HESTIA/bin" "$HESTIA/func" "$HESTIA/web" \
    \( -name "*.rej" -o -name "*.orig" \) -delete 2>/dev/null

# patch devuelve 1 cuando algun trozo ya estaba aplicado (--forward): eso no
# es un fallo. Solo es fallo si quedaron .rej o si algo no se pudo aplicar.
if echo "$SALIDA" | grep -q "FAILED\|malformed\|can't find file"; then
    bad "El parche no se aplico limpiamente. Restaurando el backup..."
    # Aviso visible en el panel: si esto ocurre tras un apt upgrade, el limite
    # de subdominios deja de aplicarse y hay que enterarse, no descubrirlo
    # cuando un cliente cree dominios que no deberia poder crear.
    "$HESTIA/bin/v-add-user-notification" admin \
        "QemuCP: limite de subdominios DESACTIVADO" \
        "El parche no se pudo reaplicar sobre esta version de HestiaCP. Los paquetes con WEB_SUBDOMAINS han dejado de limitar subdominios. Revisa /var/log/qemucp-subdominios.log" \
        2>/dev/null || true
    for F in $FICHEROS; do cp -a "$BACKUP/$F" "$HESTIA/$F"; done
    find "$HESTIA" -name "*.rej" -newer "$BACKUP" -delete 2>/dev/null
    bad "Sin cambios. Revisa la version de QemuCP: este parche es para 1.10.5."
    exit 1
fi
[ "$RES" -ne 0 ] && warn "patch devolvio $RES (normal si ya estaba aplicado)"

fi   # fin de: if [ "$YA_APLICADO" = "no" ]

# -------------------------------------------------------------- verificacion
echo ""
echo "--- Verificando ---"
ERR=0
for F in func/main.sh bin/v-add-web-domain bin/v-change-user-package bin/v-update-user-counters; do
    if bash -n "$HESTIA/$F" 2>/dev/null; then ok "sintaxis bash $F"; else bad "sintaxis bash ROTA en $F"; ERR=1; fi
done
PHPBIN=$(command -v php || ls /usr/bin/php* 2>/dev/null | head -1)
if [ -n "$PHPBIN" ]; then
    for F in web/add/package/index.php web/edit/package/index.php \
             web/templates/pages/add_package.php web/templates/pages/edit_package.php; do
        if $PHPBIN -l "$HESTIA/$F" >/dev/null 2>&1; then ok "sintaxis php $F"; else bad "sintaxis php ROTA en $F"; ERR=1; fi
    done
else
    warn "No se encontro el binario php, no se comprueba la sintaxis PHP"
fi

for MARCA in count_web_domains_split has_split_subdomain_limit; do
    grep -q "$MARCA" "$HESTIA/func/main.sh" && ok "funcion $MARCA presente" \
        || { bad "falta $MARCA en func/main.sh"; ERR=1; }
done
grep -q "WEB_SUBDOMAINS" "$HESTIA/bin/v-add-web-domain" && ok "chequeo en v-add-web-domain" \
    || { bad "falta el chequeo en v-add-web-domain"; ERR=1; }
grep -q "v_web_subdomains" "$HESTIA/web/templates/pages/edit_package.php" && ok "campo en el formulario de paquetes" \
    || { bad "falta el campo en el formulario"; ERR=1; }

if [ "$ERR" -ne 0 ]; then
    echo ""
    bad "Verificacion con errores. Restaurando el backup..."
    for F in $FICHEROS; do cp -a "$BACKUP/$F" "$HESTIA/$F"; done
    systemctl restart hestia 2>/dev/null
    bad "Revertido. Nada quedo modificado."
    exit 1
fi

# -------------------------------------------- prueba real sin tocar nada
echo ""
echo "--- Conteo actual por usuario (solo informativo) ---"
# Se carga SOLO la funcion de conteo. No se hace 'source func/main.sh' porque
# arrastra hestia.conf y los codigos de error del panel y aborta el script.
FN=$(mktemp /tmp/qemucp-fn.XXXXXX.sh)
sed -n '/^count_web_domains_split()/,/^}/p' "$HESTIA/func/main.sh" > "$FN"
# shellcheck disable=SC1090
. "$FN"
rm -f "$FN"
printf "  %-16s %10s %13s  %s\n" USUARIO DOMINIOS SUBDOMINIOS ESQUEMA
for UD in "$HESTIA"/data/users/*/; do
    [ -d "$UD" ] || continue
    U=$(basename "$UD")
    [ -f "$UD/web.conf" ] || continue
    S=$(count_web_domains_split "$UD/web.conf")
    LIM=$(grep -m1 "^WEB_SUBDOMAINS=" "$UD/user.conf" 2>/dev/null | cut -f2 -d\')
    if [ -n "$LIM" ]; then ESQ="separado (limite $LIM)"; else ESQ="antiguo (todo en WEB_DOMAINS)"; fi
    printf "  %-16s %10s %13s  %s\n" "$U" "$(echo "$S" | cut -f1 -d' ')" "$(echo "$S" | cut -f2 -d' ')" "$ESQ"
done

systemctl restart hestia 2>/dev/null && ok "Panel reiniciado"

# ------------------------------------------------- persistencia tras apt upgrade
# El paquete hestia sobrescribe bin/ y func/ en cada actualizacion, asi que sin
# esto el limite de subdominios desaparece en silencio al primer apt upgrade.
echo ""
echo "--- Persistencia tras actualizar HestiaCP ---"
DESTINO="$HESTIA/data/qemucp"
mkdir -p "$DESTINO"
PROPIO=$(readlink -f "$0")
if [ "$PROPIO" != "$DESTINO/parche-subdominios.sh" ]; then
    cp -a "$PROPIO" "$DESTINO/parche-subdominios.sh"
    chmod +x "$DESTINO/parche-subdominios.sh"
    ok "Copia instalada en $DESTINO/parche-subdominios.sh"
fi

mkdir -p "$HESTIA/data/hooks"
HOOK="$HESTIA/data/hooks/post_update.sh"
[ -f "$HOOK" ] || { echo '#!/bin/bash' > "$HOOK"; chmod +x "$HOOK"; }
if grep -q "parche-subdominios.sh" "$HOOK" 2>/dev/null; then
    ok "El hook post-update ya lo reaplica"
else
    cat >> "$HOOK" << 'HOOKEOF'

# --- QemuCP: reaplicar el limite de subdominios (WEB_SUBDOMAINS) ---
# apt sobrescribe func/main.sh y bin/v-add-web-domain en cada actualizacion.
if [ -x /usr/local/hestia/data/qemucp/parche-subdominios.sh ]; then
    /usr/local/hestia/data/qemucp/parche-subdominios.sh \
        >> /var/log/qemucp-subdominios.log 2>&1
fi
HOOKEOF
    chmod +x "$HOOK"
    ok "Hook post-update registrado"
fi

cat <<'SIGUIENTE'

============================================================
 Parche aplicado
============================================================

Ahora mismo NADA ha cambiado para tus clientes: todos los paquetes
siguen en el esquema antiguo hasta que les pongas un valor.

Para pasar un plan al esquema cPanel, desde el panel:
  Paquetes -> editar el plan -> aparecen dos campos:
      Web Domains      -> dominios adicionales (0 = ninguno)
      Web Subdomains   -> subdominios de sus propios dominios
  Guardar. El panel propaga el plan a los usuarios que lo tengan.

Por SSH, equivalente (plan "basico": 0 adicionales, 10 subdominios):
  P=/usr/local/hestia/data/packages/basico.pkg
  sed -i "/^WEB_SUBDOMAINS=/d" $P
  sed -i "/^WEB_DOMAINS=/a WEB_SUBDOMAINS='10'" $P
  sed -i "s/^WEB_DOMAINS=.*/WEB_DOMAINS='1'/" $P
  v-update-user-package basico

  Ojo: WEB_DOMAINS='1' es el dominio PRINCIPAL. Para "sin dominios
  adicionales" el valor es 1, no 0, porque el principal tambien cuenta
  como dominio de nivel superior.

Comprobar que funciona, con un usuario de ese plan:
  v-add-web-domain USUARIO sub1.sudominio.com     <- debe dejar
  v-add-web-domain USUARIO otrodominio.es         <- debe dar
                   "WEB_DOMAINS limit is reached"

Deshacer todo:
  bash parche-subdominios.sh --revertir

SIGUIENTE
exit 0
