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

FICHEROS="func/main.sh bin/v-add-web-domain bin/v-add-domain bin/v-add-user \
bin/v-add-user-package bin/v-change-user-package bin/v-update-user-counters \
bin/v-list-user bin/v-list-user-package bin/v-list-user-packages \
web/add/package/index.php web/edit/package/index.php \
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

# ----------------------------------------------------------------- --listar
# Estado de dominios y subdominios de todos los usuarios, con su limite.
if [ "${1:-}" = "--listar" ]; then
    if ! grep -q "count_web_domains_split" "$HESTIA/func/main.sh" 2>/dev/null; then
        bad "El parche no esta aplicado. Ejecuta primero: bash $0"
        exit 1
    fi
    FN=$(mktemp /tmp/qemucp-fn.XXXXXX.sh)
    sed -n '/^count_web_domains_split()/,/^}/p' "$HESTIA/func/main.sh" > "$FN"
    # shellcheck disable=SC1090
    . "$FN"; rm -f "$FN"
    printf "%-16s %-12s %14s %16s   %s\n" USUARIO PLAN DOMINIOS SUBDOMINIOS ESQUEMA
    printf "%-16s %-12s %14s %16s   %s\n" ---------------- ------------ -------------- ---------------- -------
    for UD in "$HESTIA"/data/users/*/; do
        [ -d "$UD" ] || continue
        U=$(basename "$UD")
        [ -f "$UD/web.conf" ] || continue
        S=$(count_web_domains_split "$UD/web.conf")
        USA_D=$(echo "$S" | cut -f1 -d' '); USA_S=$(echo "$S" | cut -f2 -d' ')
        PL=$(grep -m1 "^PACKAGE=" "$UD/user.conf" 2>/dev/null | cut -f2 -d\')
        LD=$(grep -m1 "^WEB_DOMAINS=" "$UD/user.conf" 2>/dev/null | cut -f2 -d\')
        LS=$(grep -m1 "^WEB_SUBDOMAINS=" "$UD/user.conf" 2>/dev/null | cut -f2 -d\')
        if [ -n "$LS" ]; then
            ESQ="separado"
            TOTD="$USA_D/$LD"; TOTS="$USA_S/$LS"
        else
            ESQ="heredado"
            # En el esquema heredado el limite es conjunto
            TOTD="$USA_D"; TOTS="$USA_S"
            [ -n "$LD" ] && TOTD="$USA_D (cupo conjunto $((USA_D+USA_S))/$LD)"
        fi
        printf "%-16s %-12s %14s %16s   %s\n" "$U" "${PL:-?}" "$TOTD" "$TOTS" "$ESQ"
    done
    echo ""
    echo "heredado = los subdominios gastan cupo de dominios (HestiaCP de siempre)"
    echo "separado = cada uno con su limite (como cPanel)"
    echo ""
    echo "Cambiar un plan:     bash $0 --plan PLAN DOMINIOS SUBDOMINIOS"
    echo "Cambiar un usuario:  bash $0 --usuario USUARIO DOMINIOS SUBDOMINIOS"
    exit 0
fi

# ---------------------------------------------------------------- --usuario
# Limites de UN usuario concreto, sin tocar su plan ni a los demas.
if [ "${1:-}" = "--usuario" ]; then
    USU="${2:-}"; NDOM="${3:-}"; NSUB="${4:-}"
    UC="$HESTIA/data/users/$USU/user.conf"
    if [ -z "$USU" ] || [ -z "$NDOM" ] || [ -z "$NSUB" ]; then
        echo "Uso: bash $0 --usuario USUARIO DOMINIOS SUBDOMINIOS"
        echo ""
        echo "  DOMINIOS     dominios de nivel superior, INCLUIDO el principal."
        echo "  SUBDOMINIOS  numero, o 'unlimited'."
        echo ""
        echo "Afecta solo a este usuario. Lo escribe en su user.conf, por encima"
        echo "de lo que diga su plan."
        exit 1
    fi
    [ -f "$UC" ] || { bad "No existe el usuario '$USU'"; exit 1; }
    if ! grep -q "count_web_domains_split" "$HESTIA/func/main.sh" 2>/dev/null; then
        bad "El parche no esta aplicado. Ejecuta primero: bash $0"
        exit 1
    fi
    case "$NDOM" in ''|*[!0-9]*) bad "DOMINIOS debe ser un numero"; exit 1 ;; esac
    [ "$NDOM" -lt 1 ] && { bad "DOMINIOS debe ser 1 o mas: el principal tambien cuenta"; exit 1; }
    if [ "$NSUB" != "unlimited" ]; then
        case "$NSUB" in ''|*[!0-9]*) bad "SUBDOMINIOS debe ser un numero o 'unlimited'"; exit 1 ;; esac
    fi

    cp -a "$UC" "$UC.bak-$(date +%Y%m%d-%H%M%S)"
    sed -i "/^WEB_SUBDOMAINS=/d" "$UC"
    sed -i "s|^WEB_DOMAINS=.*|WEB_DOMAINS='$NDOM'|" "$UC"
    sed -i "/^WEB_DOMAINS=/a WEB_SUBDOMAINS='$NSUB'" "$UC"
    # DNS y correo no deben limitar: solo mandan dominios y subdominios
    for CLAVE in DNS_DOMAINS MAIL_DOMAINS; do
        grep -q "^$CLAVE=" "$UC" && sed -i "s|^$CLAVE=.*|$CLAVE='unlimited'|" "$UC"
    done
    grep -q "^U_WEB_SUBDOMAINS=" "$UC" || sed -i "/^U_WEB_DOMAINS=/a U_WEB_SUBDOMAINS='0'" "$UC"
    "$HESTIA/bin/v-update-user-counters" "$USU" 2>/dev/null || true
    ok "Usuario '$USU': WEB_DOMAINS='$NDOM'  WEB_SUBDOMAINS='$NSUB'"
    grep -E "^(WEB_DOMAINS|WEB_SUBDOMAINS|U_WEB_DOMAINS|U_WEB_SUBDOMAINS)=" "$UC" | sed 's/^/  /'
    echo ""
    warn "Esto es un ajuste individual: si mas adelante le cambias el PLAN"
    warn "desde el panel, estos valores se sobreescriben con los del plan."
    exit 0
fi

# ------------------------------------------------------------------- --plan
# Ajusta un paquete a "X dominios / Y subdominios" dejando coherentes TODOS
# los cupos implicados. Hace falta porque en HestiaCP cada subdominio es
# tambien una zona DNS y un dominio de correo: si DNS_DOMAINS o MAIL_DOMAINS
# se quedan cortos, el panel crea el subdominio a medias y sin dar error.
if [ "${1:-}" = "--plan" ]; then
    PLAN="${2:-}"; NDOM="${3:-}"; NSUB="${4:-}"
    PKG="$HESTIA/data/packages/${PLAN}.pkg"
    if [ -z "$PLAN" ] || [ -z "$NDOM" ] || [ -z "$NSUB" ]; then
        echo "Uso: bash $0 --plan NOMBRE DOMINIOS SUBDOMINIOS"
        echo ""
        echo "  DOMINIOS     dominios de nivel superior, INCLUIDO el principal."
        echo "               Para 'principal + 2 adicionales' pon 3."
        echo "  SUBDOMINIOS  subdominios de sus propios dominios, o 'unlimited'."
        echo ""
        echo "Ejemplos:"
        echo "  bash $0 --plan basico 1 10         1 dominio, 10 subdominios"
        echo "  bash $0 --plan pro 3 unlimited     principal + 2 adicionales"
        echo ""
        echo "Paquetes disponibles:"
        ls -1 "$HESTIA/data/packages/"*.pkg 2>/dev/null \
            | sed 's|.*/||; s|\.pkg$||; s|^|  |'
        exit 1
    fi
    [ -f "$PKG" ] || { bad "No existe el paquete '$PLAN' ($PKG)"; exit 1; }
    case "$NDOM" in ''|*[!0-9]*) bad "DOMINIOS debe ser un numero"; exit 1 ;; esac
    [ "$NDOM" -lt 1 ] && { bad "DOMINIOS debe ser 1 o mas: el dominio principal tambien cuenta"; exit 1; }
    case "$NSUB" in
        unlimited|0|[1-9]*) ;;
        *) bad "SUBDOMINIOS debe ser un numero o 'unlimited'"; exit 1 ;;
    esac
    case "$NSUB" in
        unlimited) ;;
        *[!0-9]*) bad "SUBDOMINIOS debe ser un numero o 'unlimited'"; exit 1 ;;
    esac

    if ! grep -q "count_web_domains_split" "$HESTIA/func/main.sh" 2>/dev/null; then
        bad "El parche no esta aplicado todavia. Ejecuta primero: bash $0"
        exit 1
    fi

    cp -a "$PKG" "$PKG.bak-$(date +%Y%m%d-%H%M%S)"
    sed -i "/^WEB_SUBDOMAINS=/d" "$PKG"
    sed -i "s|^WEB_DOMAINS=.*|WEB_DOMAINS='$NDOM'|" "$PKG"
    sed -i "/^WEB_DOMAINS=/a WEB_SUBDOMAINS='$NSUB'" "$PKG"
    ok "WEB_DOMAINS='$NDOM'  WEB_SUBDOMAINS='$NSUB'"

    # DNS y correo: cada subdominio consume tambien uno de esos cupos
    # DNS y correo a 'unlimited': los unicos cupos que deben limitar son
    # dominios y subdominios. Si se dejan con numero, bloquean la creacion del
    # subdominio aunque queden subdominios libres, y encima sin dar error.
    for CLAVE in DNS_DOMAINS MAIL_DOMAINS; do
        ACTUAL=$(grep -m1 "^$CLAVE=" "$PKG" | cut -f2 -d\')
        if [ "$ACTUAL" = "unlimited" ]; then
            ok "$CLAVE ya era unlimited"
        elif [ -z "$ACTUAL" ]; then
            warn "$CLAVE no estaba en el paquete, se deja como esta"
        else
            sed -i "s|^$CLAVE=.*|$CLAVE='unlimited'|" "$PKG"
            ok "$CLAVE: '$ACTUAL' -> 'unlimited' (no debe limitar nada)"
        fi
    done

    echo ""
    echo "--- Paquete '$PLAN' ---"
    grep -E "^(WEB_DOMAINS|WEB_SUBDOMAINS|WEB_ALIASES|DNS_DOMAINS|MAIL_DOMAINS)=" "$PKG" | sed 's/^/  /'
    echo ""
    echo "Significa: $((NDOM - 1)) dominios adicionales (mas el principal)"
    echo "           $NSUB subdominios de sus propios dominios"
    echo ""
    echo "--- Propagando a los usuarios de este plan ---"
    if "$HESTIA/bin/v-update-user-package" "$PLAN" 2>&1 | sed 's/^/  /'; then
        ok "Plan propagado"
    else
        warn "v-update-user-package devolvio error: revisa si algun usuario ya"
        warn "supera los nuevos limites (a esos hay que subirles el plan primero)"
    fi
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
ok "Los 13 ficheros a modificar estan presentes"

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
diff --git a/bin/v-add-domain b/bin/v-add-domain
index be69cbe50..9e11ee13d 100755
--- a/bin/v-add-domain
+++ b/bin/v-add-domain
@@ -54,7 +54,10 @@ fi
 
 # Working on web domain
 if [ -n "$WEB_SYSTEM" ]; then
-	check1=$(is_package_full 'WEB_DOMAINS')
+	# QemuCP: un subdominio cuenta contra WEB_SUBDOMAINS, no contra WEB_DOMAINS.
+	# Sin esto, con el cupo de dominios lleno pero subdominios libres, este
+	# pre-chequeo se saltaria la creacion de la parte web sin dar ningun error.
+	check1=$(is_package_full "$(web_quota_key "$domain")")
 	if [ $? -eq 0 ]; then
 		$BIN/v-add-web-domain "$user" "$domain" "$ip" 'no'
 		check_result $? "can't add web domain"
diff --git a/bin/v-add-user b/bin/v-add-user
index a0cda7871..38ce6fe1d 100755
--- a/bin/v-add-user
+++ b/bin/v-add-user
@@ -248,6 +248,7 @@ U_DISK_MAIL='0'
 U_DISK_DB='0'
 U_BANDWIDTH='0'
 U_WEB_DOMAINS='0'
+U_WEB_SUBDOMAINS='0'
 U_WEB_SSL='0'
 U_WEB_ALIASES='0'
 U_DNS_DOMAINS='0'
diff --git a/bin/v-add-user-package b/bin/v-add-user-package
index 816dc3970..7a6542e9f 100755
--- a/bin/v-add-user-package
+++ b/bin/v-add-user-package
@@ -133,6 +133,7 @@ PROXY_TEMPLATE='$PROXY_TEMPLATE'
 BACKEND_TEMPLATE='$BACKEND_TEMPLATE'
 DNS_TEMPLATE='$DNS_TEMPLATE'
 WEB_DOMAINS='$WEB_DOMAINS'
+WEB_SUBDOMAINS='${WEB_SUBDOMAINS:-unlimited}'
 WEB_ALIASES='$WEB_ALIASES'
 DNS_DOMAINS='$DNS_DOMAINS'
 DNS_RECORDS='$DNS_RECORDS'
diff --git a/bin/v-add-web-domain b/bin/v-add-web-domain
index e50498658..50ef2632b 100755
--- a/bin/v-add-web-domain
+++ b/bin/v-add-web-domain
@@ -53,7 +53,11 @@ check_args '2' "$#" 'USER DOMAIN [IP] [RESTART] [ALIASES] [PROXY_EXTENSIONS]'
 is_format_valid 'user' 'domain' 'aliases' 'ip' 'proxy_ext' 'restart'
 is_object_valid 'user' 'USER' "$user"
 is_object_unsuspended 'user' 'USER' "$user"
-is_package_full 'WEB_DOMAINS'
+
+# QemuCP: en cPanel un subdominio de un dominio que ya aloja la cuenta no gasta
+# cupo de "addon domains", sino el suyo propio. web_quota_key decide contra que
+# limite cuenta este dominio (ver func/main.sh).
+is_package_full "$(web_quota_key "$domain")"
 
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
diff --git a/bin/v-list-user b/bin/v-list-user
index 66566a4de..b851364f8 100755
--- a/bin/v-list-user
+++ b/bin/v-list-user
@@ -32,6 +32,7 @@ json_list() {
         "PROXY_TEMPLATE": "'$PROXY_TEMPLATE'",
         "DNS_TEMPLATE": "'$DNS_TEMPLATE'",
         "WEB_DOMAINS": "'$WEB_DOMAINS'",
+        "WEB_SUBDOMAINS": "'$WEB_SUBDOMAINS'",
         "WEB_ALIASES": "'$WEB_ALIASES'",
         "DNS_DOMAINS": "'$DNS_DOMAINS'",
         "DNS_RECORDS": "'$DNS_RECORDS'",
@@ -68,6 +69,7 @@ json_list() {
         "U_DISK_DB": "'$U_DISK_DB'",
         "U_BANDWIDTH": "'$U_BANDWIDTH'",
         "U_WEB_DOMAINS": "'$U_WEB_DOMAINS'",
+        "U_WEB_SUBDOMAINS": "'$U_WEB_SUBDOMAINS'",
         "U_WEB_SSL": "'$U_WEB_SSL'",
         "U_WEB_ALIASES": "'$U_WEB_ALIASES'",
         "U_DNS_DOMAINS": "'$U_DNS_DOMAINS'",
@@ -104,6 +106,7 @@ shell_list() {
 	echo "PACKAGE:       $PACKAGE"
 	echo "SHELL:         $SHELL"
 	echo "WEB DOMAINS:   $U_WEB_DOMAINS/$WEB_DOMAINS"
+	echo "WEB SUBDOMAINS: ${U_WEB_SUBDOMAINS:-0}/${WEB_SUBDOMAINS:-n/a}"
 	echo "WEB ALIASES:   $U_WEB_ALIASES/$WEB_ALIASES"
 	echo "DNS DOMAINS:   $U_DNS_DOMAINS/$DNS_DOMAINS"
 	echo "DNS RECORDS:   $U_DNS_RECORDS/$DNS_RECORDS"
diff --git a/bin/v-list-user-package b/bin/v-list-user-package
index f0b0e3cb7..ef64d14e3 100755
--- a/bin/v-list-user-package
+++ b/bin/v-list-user-package
@@ -29,6 +29,7 @@ json_list() {
         "PROXY_TEMPLATE": "'$PROXY_TEMPLATE'",
         "DNS_TEMPLATE": "'$DNS_TEMPLATE'",
         "WEB_DOMAINS": "'$WEB_DOMAINS'",
+        "WEB_SUBDOMAINS": "'$WEB_SUBDOMAINS'",
         "WEB_ALIASES": "'$WEB_ALIASES'",
         "DNS_DOMAINS": "'$DNS_DOMAINS'",
         "DNS_RECORDS": "'$DNS_RECORDS'",
@@ -61,6 +62,7 @@ shell_list() {
 	echo "PROXY TEMPLATE:   $PROXY_TEMPLATE"
 	echo "DNS TEMPLATE:     $DNS_TEMPLATE"
 	echo "WEB DOMAINS:      $WEB_DOMAINS"
+	echo "WEB SUBDOMAINS:   $WEB_SUBDOMAINS"
 	echo "WEB ALIASES:      $WEB_ALIASES"
 	echo "DNS DOMAINS:      $DNS_DOMAINS"
 	echo "DNS RECORDS:      $DNS_RECORDS"
diff --git a/bin/v-list-user-packages b/bin/v-list-user-packages
index 1b90a04e7..06d9173b1 100755
--- a/bin/v-list-user-packages
+++ b/bin/v-list-user-packages
@@ -27,12 +27,16 @@ json_list() {
 	echo "{"
 	for package in $packages; do
 		PACKAGE=${package/.pkg/}
+		# QemuCP: limpiar antes de cada source_conf. Es un bucle, y un paquete
+		# sin WEB_SUBDOMAINS heredaria el valor del paquete anterior.
+		WEB_SUBDOMAINS=''
 		source_conf "$HESTIA/data/packages/$PACKAGE.pkg"
 		echo -n '    "'$PACKAGE'": {
         "WEB_TEMPLATE": "'$WEB_TEMPLATE'",
         "PROXY_TEMPLATE": "'$PROXY_TEMPLATE'",
         "DNS_TEMPLATE": "'$DNS_TEMPLATE'",
         "WEB_DOMAINS": "'$WEB_DOMAINS'",
+        "WEB_SUBDOMAINS": "'$WEB_SUBDOMAINS'",
         "WEB_ALIASES": "'$WEB_ALIASES'",
         "DNS_DOMAINS": "'$DNS_DOMAINS'",
         "DNS_RECORDS": "'$DNS_RECORDS'",
diff --git a/bin/v-update-user-counters b/bin/v-update-user-counters
index 586f8aa1c..a5d1ed452 100755
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
@@ -210,6 +219,7 @@ for user in $user_list; do
 	update_user_value "$user" '$U_DISK_DB' "$U_DISK_DB"
 	update_user_value "$user" '$U_BANDWIDTH' "$U_BANDWIDTH"
 	update_user_value "$user" '$U_WEB_DOMAINS' "$U_WEB_DOMAINS"
+	update_user_value "$user" '$U_WEB_SUBDOMAINS' "$U_WEB_SUBDOMAINS"
 	update_user_value "$user" '$U_WEB_SSL' "$U_WEB_SSL"
 	update_user_value "$user" '$U_WEB_ALIASES' "$U_WEB_ALIASES"
 	update_user_value "$user" '$U_DNS_DOMAINS' "$U_DNS_DOMAINS"
diff --git a/func/main.sh b/func/main.sh
index 8b59d2e26..a78e9307b 100644
--- a/func/main.sh
+++ b/func/main.sh
@@ -267,10 +267,81 @@ is_system_enabled() {
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
+# QemuCP: nombre del limite contra el que debe contar el dominio indicado.
+# Devuelve WEB_SUBDOMAINS si es X.DOMINIO de un dominio que ya aloja este
+# usuario y su paquete separa subdominios; WEB_DOMAINS en el resto de casos.
+# Centralizado aqui porque lo necesitan v-add-web-domain y v-add-domain, y si
+# cada uno lo decidiera por su cuenta se descuadrarian: v-add-domain
+# pre-comprueba el limite y se salta la creacion web sin avisar.
+web_quota_key() {
+	local _dom="$1" _p
+	if ! has_split_subdomain_limit; then
+		echo 'WEB_DOMAINS'
+		return
+	fi
+	for _p in $(grep -o "DOMAIN='[^']*'" "$USER_DATA/web.conf" 2> /dev/null | cut -f 2 -d \'); do
+		[ "$_dom" = "$_p" ] && continue
+		case "$_dom" in
+			*".$_p")
+				echo 'WEB_SUBDOMAINS'
+				return
+				;;
+		esac
+	done
+	echo 'WEB_DOMAINS'
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
@@ -281,6 +352,10 @@ is_package_full() {
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
index 32d5e2507..bb2b10b09 100644
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
@@ -196,6 +200,9 @@ if (!empty($_POST["ok"])) {
 			}
 			$pkg .= "DNS_TEMPLATE=" . $v_dns_template . "\n";
 			$pkg .= "WEB_DOMAINS=" . $v_web_domains . "\n";
+			if (trim($_POST["v_web_subdomains"]) !== "") {
+				$pkg .= "WEB_SUBDOMAINS=" . $v_web_subdomains . "\n";
+			}
 			$pkg .= "WEB_ALIASES=" . $v_web_aliases . "\n";
 			$pkg .= "DNS_DOMAINS=" . $v_dns_domains . "\n";
 			$pkg .= "DNS_RECORDS=" . $v_dns_records . "\n";
@@ -297,6 +304,9 @@ if (empty($v_shell)) {
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
index 6085f5e9d..e02cb361a 100644
--- a/web/edit/package/index.php
+++ b/web/edit/package/index.php
@@ -40,6 +40,10 @@ $v_backend_template = $data[$v_package]["BACKEND_TEMPLATE"];
 $v_proxy_template = $data[$v_package]["PROXY_TEMPLATE"];
 $v_dns_template = $data[$v_package]["DNS_TEMPLATE"];
 $v_web_domains = $data[$v_package]["WEB_DOMAINS"];
+// Vacio = paquete heredado: los subdominios siguen contando como dominios.
+// No se rellena con "unlimited" para que editar otro campo del paquete no
+// cambie el esquema sin que el administrador lo pida expresamente.
+$v_web_subdomains = $data[$v_package]["WEB_SUBDOMAINS"] ?? "";
 $v_web_aliases = $data[$v_package]["WEB_ALIASES"];
 $v_dns_domains = $data[$v_package]["DNS_DOMAINS"];
 $v_dns_records = $data[$v_package]["DNS_RECORDS"];
@@ -163,6 +167,9 @@ if (!empty($_POST["save"])) {
 	if (!isset($_POST["v_web_domains"])) {
 		$errors[] = _("Web Domains");
 	}
+	if (!isset($_POST["v_web_subdomains"])) {
+		$errors[] = _("Web Subdomains");
+	}
 	if (!isset($_POST["v_web_aliases"])) {
 		$errors[] = _("Web Aliases");
 	}
@@ -253,6 +260,7 @@ if (!empty($_POST["save"])) {
 		$v_shell = "nologin";
 	}
 	$v_web_domains = quoteshellarg($_POST["v_web_domains"]);
+	$v_web_subdomains = quoteshellarg($_POST["v_web_subdomains"]);
 	$v_web_aliases = quoteshellarg($_POST["v_web_aliases"]);
 	$v_dns_domains = quoteshellarg($_POST["v_dns_domains"]);
 	$v_dns_records = quoteshellarg($_POST["v_dns_records"]);
@@ -312,6 +320,9 @@ if (!empty($_POST["save"])) {
 	$pkg .= "PROXY_TEMPLATE=" . $v_proxy_template . "\n";
 	$pkg .= "DNS_TEMPLATE=" . $v_dns_template . "\n";
 	$pkg .= "WEB_DOMAINS=" . $v_web_domains . "\n";
+	if (trim($_POST["v_web_subdomains"]) !== "") {
+		$pkg .= "WEB_SUBDOMAINS=" . $v_web_subdomains . "\n";
+	}
 	$pkg .= "WEB_ALIASES=" . $v_web_aliases . "\n";
 	$pkg .= "DNS_DOMAINS=" . $v_dns_domains . "\n";
 	$pkg .= "DNS_RECORDS=" . $v_dns_records . "\n";
diff --git a/web/templates/pages/add_package.php b/web/templates/pages/add_package.php
index 111df452d..671315575 100644
--- a/web/templates/pages/add_package.php
+++ b/web/templates/pages/add_package.php
@@ -81,6 +81,17 @@
 							</button>
 						</div>
 					</div>
+					<div class="u-mb10">
+						<label for="v_web_subdomains" class="form-label">
+							<?= tohtml( _("Web Subdomains")) ?> <span class="optional">(<?= tohtml( _("subdomains of own domains; empty = count as domains")) ?>)</span>
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
index 0272fd99b..cbcb57ab5 100644
--- a/web/templates/pages/edit_package.php
+++ b/web/templates/pages/edit_package.php
@@ -83,6 +83,17 @@
 							</button>
 						</div>
 					</div>
+					<div class="u-mb10">
+						<label for="v_web_subdomains" class="form-label">
+							<?= tohtml( _("Web Subdomains")) ?> <span class="optional">(<?= tohtml( _("subdomains of own domains; empty = count as domains")) ?>)</span>
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
for F in func/main.sh bin/v-add-web-domain bin/v-add-domain bin/v-add-user bin/v-add-user-package bin/v-change-user-package bin/v-update-user-counters bin/v-list-user bin/v-list-user-package bin/v-list-user-packages; do
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
for B in v-add-web-domain v-add-domain; do
    grep -q "web_quota_key" "$HESTIA/bin/$B" && ok "chequeo de cupo en $B" \
        || { bad "falta el chequeo de cupo en $B"; ERR=1; }
done
grep -q "web_quota_key" "$HESTIA/func/main.sh" && ok "funcion web_quota_key presente" \
    || { bad "falta web_quota_key en func/main.sh"; ERR=1; }
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
