#!/bin/bash
# ============================================================
# QemuCP - Importador de Backup Oficial cPanel
# Version: 2.0
#
# Uso: bash cpanel-import.sh /ruta/backup_cpanel.tar.gz [usuario_destino] [plan]
#
#   usuario_destino  por defecto, el mismo usuario que en cPanel
#   plan             plan de QemuCP para el usuario nuevo (por defecto 'default')
#                    Antes de crear nada se comprueba que el plan cubre los
#                    dominios, subdominios, bases de datos... del backup.
#
# Variables opcionales:
#   QEMUCP_PLAN=plan                 igual que el tercer argumento
#   QEMUCP_IGNORAR_LIMITES=si        importar aunque el plan se quede corto
#   QEMUCP_CORREO_LOCAL=dom1,dom2    forzar correo LOCAL en esos dominios
#   QEMUCP_CORREO_EXTERNO=dom1,dom2  forzar correo EXTERNO en esos dominios
#
# Importa: dominio principal, dominios adicionales, subdominios (tambien los
# de los dominios adicionales), dominios aparcados (alias), ficheros, bases de
# datos, cuentas de correo con su contrasena original, reenviadores,
# reenviadores de dominio, cuenta por defecto, crons, zonas DNS y SSL vigente.
# Al terminar comprueba cada zona DNS y lista lo que haya que revisar a mano.
# ============================================================

set -euo pipefail

BACKUP="${1:-}"
FORCE_USER="${2:-}"
PLAN="${3:-${QEMUCP_PLAN:-default}}"
HESTIA="/usr/local/hestia"
BIN="$HESTIA/bin"
LOG="/var/log/qemucp-cpanel-import.log"
WORK_DIR=""
DB_CREATED=()  # "DB_FINAL:DB_USER:DB_PASS" creadas en esta ejecucion
CREDS_FILE="/root/qemucp-import-credentials.txt"
PENDIENTES=()  # cosas que hay que revisar a mano (se listan al final)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG"; }
error()  { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG"; [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR"; exit 1; }
header() { echo -e "\n${BLUE}========================================${NC}" | tee -a "$LOG"
           echo -e "${BLUE} $1${NC}" | tee -a "$LOG"
           echo -e "${BLUE}========================================${NC}" | tee -a "$LOG"; }
info()   { echo -e "  -> $1" | tee -a "$LOG"; }
pendiente() { PENDIENTES+=("$1"); warn "$1"; }

DOM_RE='^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
es_dominio() { [[ "$1" =~ $DOM_RE ]]; }
# Numero de etiquetas (blog.dominio.com = 3): los padres se crean antes que
# sus subdominios, porque QemuCP decide si algo es subdominio mirando si su
# dominio padre ya existe en la cuenta.
etiquetas() { local s="${1//[^.]/}"; echo $(( ${#s} + 1 )); }
en_lista() { local x="$1"; shift; local i; for i in "$@"; do [[ "$i" == "$x" ]] && return 0; done; return 1; }

# -- Validaciones ------------------------------------------------
[[ $EUID -ne 0 ]] && error "Ejecuta como root"
[[ -z "$BACKUP" ]] && error "Uso: bash cpanel-import.sh /ruta/backup.tar.gz [usuario_destino] [plan]"
[[ ! -f "$BACKUP" ]] && error "Fichero no encontrado: $BACKUP"
[[ ! -f "$HESTIA/conf/hestia.conf" ]] && error "QemuCP no instalado"
for _h in rsync openssl; do
    command -v "$_h" >/dev/null 2>&1 || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$_h" >/dev/null 2>&1 \
        || error "Falta $_h y no se pudo instalar"
done

echo "QemuCP cPanel Import - $(date)" > "$LOG"
header "QemuCP - Importador de Backup cPanel"
log "Backup: $BACKUP ($(du -sh "$BACKUP" | cut -f1))"

# -- Descomprimir ------------------------------------------------
header "Descomprimiendo backup"
# Espacio: el backup se descomprime (hasta ~3 veces su tamano) y luego se
# copia a /home. Sin espacio la importacion se corta a medias.
# QEMUCP_TMP=/ruta para descomprimir en otro disco.
TMP_BASE="${QEMUCP_TMP:-/tmp}"
BK_MB=$(( $(stat -c %s "$BACKUP") / 1048576 + 1 ))
LIBRE_TMP=$(df -Pm "$TMP_BASE" | awk 'NR==2 {print $4}')
LIBRE_HOME=$(df -Pm /home | awk 'NR==2 {print $4}')
if [[ "$(df -P "$TMP_BASE" | awk 'NR==2 {print $1}')" == "$(df -P /home | awk 'NR==2 {print $1}')" ]]; then
    NECESITA=$(( BK_MB * 6 ))   # mismo disco: descomprimido + copia final
else
    NECESITA=$(( BK_MB * 3 ))
    [[ "$LIBRE_HOME" -ge $(( BK_MB * 3 )) ]] || error "No hay espacio en /home: libres ${LIBRE_HOME}MB, hacen falta unos $(( BK_MB * 3 ))MB"
fi
[[ "$LIBRE_TMP" -ge "$NECESITA" ]] \
    || error "No hay espacio para descomprimir en $TMP_BASE: libres ${LIBRE_TMP}MB, hacen falta unos ${NECESITA}MB (usa QEMUCP_TMP=/otra/ruta)"
WORK_DIR=$(mktemp -d "$TMP_BASE/cpanel-import-XXXXXX")
tar -xzf "$BACKUP" -C "$WORK_DIR" 2>/dev/null || tar -xf "$BACKUP" -C "$WORK_DIR" 2>/dev/null \
    || error "Error descomprimiendo backup"

# Detectar directorio raiz
BACKUP_PATH="$WORK_DIR"
FIRST=$(ls "$WORK_DIR" | head -1)
[[ -d "$WORK_DIR/$FIRST" && $(ls "$WORK_DIR" | wc -l) -eq 1 ]] && BACKUP_PATH="$WORK_DIR/$FIRST"
log "Raiz del backup: $BACKUP_PATH"
log "Contenido: $(ls "$BACKUP_PATH" | tr '\n' ' ')"

# Algunas versiones de cPanel guardan el home como homedir.tar aparte
if [[ ! -d "$BACKUP_PATH/homedir" && -f "$BACKUP_PATH/homedir.tar" ]]; then
    mkdir -p "$BACKUP_PATH/homedir"
    tar -xf "$BACKUP_PATH/homedir.tar" -C "$BACKUP_PATH/homedir" 2>/dev/null \
        && log "homedir.tar descomprimido" || warn "No se pudo descomprimir homedir.tar"
fi
HOMEDIR="$BACKUP_PATH/homedir"

# -- Detectar usuario cPanel ------------------------------------
ORIG_USER=""
[[ -f "$BACKUP_PATH/cp/username" ]] && ORIG_USER=$(tr -d ' \n\r' < "$BACKUP_PATH/cp/username")
if [[ -z "$ORIG_USER" ]]; then
    for f in "$BACKUP_PATH"/cp/*; do
        [[ -f "$f" ]] || continue
        grep -q "^DNS=" "$f" 2>/dev/null && { ORIG_USER=$(basename "$f"); break; }
    done
fi
if [[ -z "$ORIG_USER" ]]; then
    FILENAME=$(basename "$BACKUP"); FILENAME="${FILENAME%.tar.gz}"; FILENAME="${FILENAME%.tar}"
    ORIG_USER=$(echo "$FILENAME" | sed 's/^backup-[0-9.]*_[0-9-]*_//')
    [[ "$ORIG_USER" == "$FILENAME" ]] && ORIG_USER=$(echo "$FILENAME" | sed 's/^cpbackup-[0-9-]*_//')
    [[ "$ORIG_USER" == "$FILENAME" ]] && ORIG_USER=$(echo "$FILENAME" | awk -F_ '{print $NF}')
fi
ORIG_USER=$(echo "$ORIG_USER" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_' | sed 's/^_*//;s/_*$//')
CPANEL_USER="${FORCE_USER:-$ORIG_USER}"
[[ -z "$CPANEL_USER" ]] && error "No se pudo detectar el usuario. Usa: bash cpanel-import.sh backup.tar.gz usuario"
log "Usuario cPanel: $ORIG_USER -> usuario QemuCP: $CPANEL_USER"
CP_USER_FILE="$BACKUP_PATH/cp/$ORIG_USER"

# ============================================================
#  DOMINIOS
# ============================================================
# Fuente principal: userdata/main, que es donde cPanel guarda QUE es cada
# dominio:
#   main_domain: principal.com
#   addon_domains:
#     adicional.com: adicional.principal.com     <- subdominio interno
#   parked_domains:
#     - aparcado.com
#   sub_domains:
#     - adicional.principal.com                  <- el interno, NO se crea
#     - blog.principal.com
#     - tienda.adicional.com
# Cada dominio adicional lleva un subdominio interno: NO es una web del
# cliente y no debe crearse (gastaria cupo de subdominios). La carpeta web
# del adicional esta en userdata/<subdominio interno>.
header "Detectando dominios"

MAIN_DOMAIN=""
ADDON_DOMAINS=()
SUB_DOMAINS=()
PARKED_DOMAINS=()
declare -A ADDON_LINK=()     # adicional -> subdominio interno
declare -A DOCROOT_ORIG=()   # dominio -> carpeta web en el servidor cPanel

UD_MAIN="$BACKUP_PATH/userdata/main"
if [[ -f "$UD_MAIN" ]]; then
    while read -r kind a b; do
        case "$kind" in
            main)   MAIN_DOMAIN="$a" ;;
            addon)  es_dominio "$a" && { ADDON_DOMAINS+=("$a"); ADDON_LINK["$a"]="$b"; } ;;
            parked) es_dominio "$a" && PARKED_DOMAINS+=("$a") ;;
            sub)    es_dominio "$a" && SUB_DOMAINS+=("$a") ;;
        esac
    done < <(awk '
        { gsub(/\r/, "") }
        /^[ \t]*-[ \t]+[^ \t]/ {
            v = $0; sub(/^[ \t]*-[ \t]+/, "", v); gsub(/["\047 \t]/, "", v)
            if (sec == "parked_domains") print "parked", tolower(v)
            else if (sec == "sub_domains") print "sub", tolower(v)
            next
        }
        /^[^ \t#-][^:]*:/ {
            sec = $0; sub(/:.*/, "", sec)
            v = $0; sub(/^[^:]*:[ \t]*/, "", v); gsub(/["\047 \t]/, "", v)
            if (sec == "main_domain" && v != "") print "main", tolower(v)
            next
        }
        /^[ \t]+[^ \t-][^:]*:/ {
            if (sec == "addon_domains") {
                k = $0; sub(/^[ \t]+/, "", k); v = k
                sub(/:.*/, "", k); sub(/^[^:]*:[ \t]*/, "", v)
                gsub(/["\047 \t]/, "", k); gsub(/["\047 \t]/, "", v)
                print "addon", tolower(k), tolower(v)
            }
        }' "$UD_MAIN")
    log "Tipos de dominio leidos de userdata/main"
fi

# Respaldo para backups sin userdata/main (muy antiguos o incompletos)
if [[ -z "$MAIN_DOMAIN" ]]; then
    warn "Sin userdata/main: se deducen los tipos de dominio (revisar el resultado)"
    [[ -f "$BACKUP_PATH/cp/main_domain" ]] && MAIN_DOMAIN=$(tr -d ' \n\r' < "$BACKUP_PATH/cp/main_domain")
    [[ -z "$MAIN_DOMAIN" && -f "$CP_USER_FILE" ]] && \
        MAIN_DOMAIN=$( { grep -m1 "^DNS=" "$CP_USER_FILE" || true; } | cut -d= -f2 | tr -d ' \r')
    MAIN_DOMAIN="${MAIN_DOMAIN,,}"
    CANDIDATOS=()
    if [[ -f "$CP_USER_FILE" ]]; then
        while IFS='=' read -r _k v; do CANDIDATOS+=("$(echo "${v,,}" | tr -d ' \r')"); done \
            < <(grep -E "^DNS[0-9]+=" "$CP_USER_FILE" 2>/dev/null || true)
    fi
    for Z in "$BACKUP_PATH"/dnszones/*.db; do [[ -f "$Z" ]] && CANDIDATOS+=("$(basename "${Z,,}" .db)"); done
    for c in $(printf '%s\n' "${CANDIDATOS[@]:-}" | sort -u); do
        es_dominio "$c" || continue
        [[ "$c" == "$MAIN_DOMAIN" ]] && continue
        if [[ -f "$BACKUP_PATH/userdata/$c" ]] || [[ -d "$HOMEDIR/$c" ]] || [[ -d "$HOMEDIR/public_html/$c" ]]; then
            ADDON_DOMAINS+=("$c")
        else
            PARKED_DOMAINS+=("$c")
        fi
    done
    for f in "$BACKUP_PATH"/userdata/*; do
        [[ -f "$f" ]] || continue
        d=$(basename "$f")
        case "$d" in main|cache|*.yaml|*.yaml.*|*_SSL|*.json|*.cache|*.bak|*.transferred) continue ;; esac
        es_dominio "$d" || continue
        [[ "$d" == "$MAIN_DOMAIN" ]] && continue
        en_lista "$d" "${ADDON_DOMAINS[@]:-}" && continue
        SUB_DOMAINS+=("$d")
    done
fi
[[ -z "$MAIN_DOMAIN" ]] && error "No se pudo detectar el dominio principal del backup"

# Quitar de los subdominios los internos de los adicionales
LINKED=" ${ADDON_LINK[*]:-} "
SUBS_TMP=()
for s in "${SUB_DOMAINS[@]:-}"; do
    [[ -z "$s" ]] && continue
    [[ "$LINKED" == *" $s "* ]] && continue
    en_lista "$s" "${ADDON_DOMAINS[@]:-}" && continue
    SUBS_TMP+=("$s")
done
SUB_DOMAINS=("${SUBS_TMP[@]:-}")
# Orden: los adicionales por nombre y los subdominios de menos a mas niveles
ADDON_DOMAINS=($(printf '%s\n' "${ADDON_DOMAINS[@]:-}" | grep -v '^$' | sort -u || true))
PARKED_DOMAINS=($(printf '%s\n' "${PARKED_DOMAINS[@]:-}" | grep -v '^$' | sort -u || true))
SUB_DOMAINS=($(for s in "${SUB_DOMAINS[@]:-}"; do [[ -n "$s" ]] && echo "$(etiquetas "$s") $s"; done \
    | sort -n -k1,1 -k2,2 | awk '{print $2}' | uniq))

# Carpeta web de cada dominio en el servidor de origen
ud_docroot() {  # $1 = fichero userdata
    [[ -f "$1" ]] || return 0
    { grep -a -m1 "^documentroot:" "$1" || true; } | sed 's/^documentroot:[[:space:]]*//; s/[[:space:]]*$//' | tr -d "\"'"
}
DOCROOT_ORIG["$MAIN_DOMAIN"]=$(ud_docroot "$BACKUP_PATH/userdata/$MAIN_DOMAIN")
[[ -z "${DOCROOT_ORIG[$MAIN_DOMAIN]}" ]] && DOCROOT_ORIG["$MAIN_DOMAIN"]="/home/$ORIG_USER/public_html"
for a in "${ADDON_DOMAINS[@]:-}"; do
    [[ -z "$a" ]] && continue
    dr=$(ud_docroot "$BACKUP_PATH/userdata/${ADDON_LINK[$a]:-none}")
    [[ -z "$dr" ]] && dr=$(ud_docroot "$BACKUP_PATH/userdata/$a")
    if [[ -z "$dr" ]]; then
        for p in "$a" "public_html/$a" "${a%%.*}" "public_html/${a%%.*}"; do
            [[ -d "$HOMEDIR/$p" ]] && { dr="/home/$ORIG_USER/$p"; break; }
        done
    fi
    DOCROOT_ORIG["$a"]="$dr"
done
for s in "${SUB_DOMAINS[@]:-}"; do
    [[ -z "$s" ]] && continue
    dr=$(ud_docroot "$BACKUP_PATH/userdata/$s")
    if [[ -z "$dr" ]]; then
        for p in "public_html/${s%%.*}" "${s%%.*}" "$s"; do
            [[ -d "$HOMEDIR/$p" ]] && { dr="/home/$ORIG_USER/$p"; break; }
        done
    fi
    DOCROOT_ORIG["$s"]="$dr"
done
# Ruta dentro del backup de una carpeta del servidor de origen
ruta_backup() {  # /home/usuario/public_html/x -> $HOMEDIR/public_html/x
    local p="$1"
    [[ -z "$p" ]] && return 0
    p="${p#/home/$ORIG_USER/}"; p="${p#/home*/$ORIG_USER/}"
    [[ "$p" == /* ]] && p="${p#/*/*/}"
    echo "$HOMEDIR/${p%/}"
}

WEB_DOMAINS_ALL=("$MAIN_DOMAIN")
for d in "${ADDON_DOMAINS[@]:-}" "${SUB_DOMAINS[@]:-}"; do [[ -n "$d" ]] && WEB_DOMAINS_ALL+=("$d"); done

log "Dominio principal: $MAIN_DOMAIN"
log "Dominios adicionales (${#ADDON_DOMAINS[@]}): ${ADDON_DOMAINS[*]:-ninguno}"
log "Subdominios: ${SUB_DOMAINS[*]:-ninguno}"
log "Dominios aparcados / alias: ${PARKED_DOMAINS[*]:-ninguno}"
for d in "${WEB_DOMAINS_ALL[@]}"; do info "$d -> ${DOCROOT_ORIG[$d]:-(sin carpeta en el backup)}"; done

# ============================================================
#  ZONAS DNS: PARSEO Y CLASIFICACION DEL CORREO
# ============================================================
# Normaliza un fichero de zona BIND a "nombre<TAB>tipo<TAB>valor" con nombres
# absolutos (sin punto final). Resuelve $ORIGIN, nombre omitido (se hereda el
# anterior), TTL y clase opcionales, parentesis multilinea y comentarios.
normalizar_zona() {  # $1 fichero  $2 dominio
    awk -v dom="${2,,}" '
    function quitar_comentario(s,   i, c, q, out) {
        q = 0; out = ""
        for (i = 1; i <= length(s); i++) {
            c = substr(s, i, 1)
            if (c == "\"" && substr(s, i - 1, 1) != "\\") q = !q
            if (c == ";" && !q && substr(s, i - 1, 1) != "\\") break
            out = out c
        }
        return out
    }
    function absoluto(n) {
        if (n == "@" || n == "") return origin
        if (n ~ /\.$/) return tolower(n)
        return tolower(n) "." origin
    }
    BEGIN { origin = dom "."; last = origin; depth = 0; buf = "" }
    {
        l = quitar_comentario($0); gsub(/\r/, "", l)
        if (depth > 0) {
            buf = buf " " l; t = l; o = gsub(/\(/, "", t); t = l; c = gsub(/\)/, "", t)
            depth += o - c; if (depth > 0) next
            l = buf; buf = ""; blank = sb
        } else {
            t = l; o = gsub(/\(/, "", t); t = l; c = gsub(/\)/, "", t)
            if (o > c) { depth = o - c; buf = l; sb = (l ~ /^[ \t]/); next }
            blank = (l ~ /^[ \t]/)
        }
        gsub(/[()]/, " ", l)
        if (l ~ /^[ \t]*$/) next
        if (l ~ /^\$ORIGIN/) { split(l, f, /[ \t]+/); origin = absoluto(f[2]); next }
        if (l ~ /^\$/) next
        rest = l
        if (blank) { name = last; sub(/^[ \t]+/, "", rest) }
        else { match(rest, /^[^ \t]+/); name = absoluto(substr(rest, 1, RLENGTH)); rest = substr(rest, RLENGTH + 1); sub(/^[ \t]+/, "", rest) }
        last = name
        type = ""
        while (rest != "") {
            match(rest, /^[^ \t]+/); tok = substr(rest, 1, RLENGTH)
            nrest = substr(rest, RLENGTH + 1); sub(/^[ \t]+/, "", nrest)
            if (tok ~ /^[0-9]+[smhdwSMHDW]?$/ && type == "") { rest = nrest; continue }
            if (toupper(tok) ~ /^(IN|CH|HS)$/) { rest = nrest; continue }
            type = toupper(tok); rest = nrest; break
        }
        if (type == "") next
        val = rest; sub(/[ \t]+$/, "", val)
        if (type == "CNAME" || type == "NS") val = absoluto(val)
        else if (type == "MX") { split(val, f, /[ \t]+/); val = f[1] " " absoluto(f[2]) }
        else if (type == "SRV") { split(val, f, /[ \t]+/); val = f[1] " " f[2] " " f[3] " " absoluto(f[4]) }
        sub(/\.$/, "", name)
        print name "\t" type "\t" val
    }' "$1"
}

ZONAS_DIR=""
for D in "$BACKUP_PATH/dnszones" "$BACKUP_PATH/dns"; do [[ -d "$D" ]] && { ZONAS_DIR="$D"; break; }; done
declare -A ZONA_TSV=()
if [[ -n "$ZONAS_DIR" ]]; then
    for Z in "$ZONAS_DIR"/*.db; do
        [[ -f "$Z" ]] || continue
        zd=$(basename "${Z,,}" .db)
        es_dominio "$zd" || continue
        ZONA_TSV["$zd"]="$WORK_DIR/zona-$zd.tsv"
        normalizar_zona "$Z" "$zd" > "${ZONA_TSV[$zd]}"
    done
fi

es_ip_privada() { [[ "$1" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|127\.) ]]; }

# IPs del servidor de ORIGEN: solo los registros que apuntan a ellas se
# cambian a este servidor. Un A que apunta a otro sitio (tienda, CRM, una
# web alojada fuera) se respeta tal cual.
ORIGIN_IPS=()
ORIGIN_IP6=()
if [[ -f "$CP_USER_FILE" ]]; then
    ip=$( { grep -m1 "^IP=" "$CP_USER_FILE" || true; } | cut -d= -f2 | tr -d ' \r')
    [[ -n "$ip" ]] && ORIGIN_IPS+=("$ip")
fi
for f in "$BACKUP_PATH"/userdata/*; do
    [[ -f "$f" ]] || continue
    ip=$( { grep -a -m1 "^ip:" "$f" || true; } | awk '{print $2}' | tr -d "\"' \r")
    [[ "$ip" =~ ^[0-9.]+$ ]] && ORIGIN_IPS+=("$ip")
done
# El dominio principal estaba alojado en el origen: su A tambien es del origen
# (necesario cuando el servidor cPanel estaba detras de NAT con IP privada).
if [[ -n "${ZONA_TSV[$MAIN_DOMAIN]:-}" ]]; then
    while IFS=$'\t' read -r n t v; do
        [[ "$n" == "$MAIN_DOMAIN" && "$t" == "A" ]] && ORIGIN_IPS+=("$v")
        [[ "$n" == "$MAIN_DOMAIN" && "$t" == "AAAA" ]] && ORIGIN_IP6+=("${v,,}")
    done < "${ZONA_TSV[$MAIN_DOMAIN]}"
fi
ORIGIN_IPS=($(printf '%s\n' "${ORIGIN_IPS[@]:-}" | grep -v '^$' | sort -u || true))
ORIGIN_IP6=($(printf '%s\n' "${ORIGIN_IP6[@]:-}" | grep -v '^$' | sort -u || true))
log "IPs del servidor de origen: ${ORIGIN_IPS[*]:-no detectadas} ${ORIGIN_IP6[*]:-}"

# Dominio registrable aproximado (ultimas 2 etiquetas, 3 en co.uk, com.es...)
dominio_base() {
    local h="${1%.}" n
    IFS=. read -ra L <<< "$h"; n=${#L[@]}
    if (( n >= 3 )) && (( ${#L[n-1]} == 2 )) && [[ "${L[n-2]}" =~ ^(co|com|net|org|gob|edu|ac|gov)$ ]]; then
        echo "${L[n-3]}.${L[n-2]}.${L[n-1]}"
    elif (( n >= 2 )); then
        echo "${L[n-2]}.${L[n-1]}"
    else
        echo "$h"
    fi
}

# Correo EXTERNO = el MX preferente apunta fuera del servidor de origen.
# Se considera LOCAL si el MX:
#   - esta dentro del propio dominio (mail.dominio.com, dominio.com)
#   - resuelve a una IP del servidor de origen
#   - pertenece al mismo proveedor que los NS de la zona (MX al hostname del
#     servidor del hosting: server12.webempresa.eu con NS *.webempresa.eu)
# En cualquier otro caso (Google, Microsoft, Zoho, IONOS...) es externo.
declare -A CORREO_EXTERNO=()   # dominio -> host MX externo
csv_tiene() { [[ ",${1}," == *",$2,"* ]]; }
for zd in "${!ZONA_TSV[@]}"; do
    MXT=$(awk -F'\t' -v z="$zd" '$1 == z && $2 == "MX" { split($3, f, " "); print f[1], f[2] }' "${ZONA_TSV[$zd]}" \
          | sort -n | head -1 | awk '{print $2}')
    MXT="${MXT%.}"
    [[ -z "$MXT" ]] && continue
    if csv_tiene "${QEMUCP_CORREO_LOCAL:-}" "$zd"; then continue; fi
    if csv_tiene "${QEMUCP_CORREO_EXTERNO:-}" "$zd"; then CORREO_EXTERNO["$zd"]="$MXT"; continue; fi
    # MX dentro del propio dominio (mail.dominio.com): es local salvo que ese
    # nombre apunte, en la propia zona, a una IP que no es del servidor de
    # origen (correo en otro servidor con un nombre del dominio).
    if [[ "$MXT" == "$zd" || "$MXT" == *".$zd" ]]; then
        MX_IPS=$(awk -F'\t' -v h="$MXT" '$1 == h && $2 == "A" { print $3 }' "${ZONA_TSV[$zd]}")
        MX_FUERA=""
        if [[ -n "$MX_IPS" ]]; then
            MX_FUERA="si"
            for ip in $MX_IPS; do en_lista "$ip" "${ORIGIN_IPS[@]:-}" && MX_FUERA=""; done
        fi
        if [[ -n "$MX_FUERA" ]]; then
            CORREO_EXTERNO["$zd"]="$MXT"
            warn "MX de $zd: $MXT apunta a $(echo $MX_IPS), que no es el servidor cPanel"
        fi
        continue
    fi
    LOCAL_MX="no"
    for ip in $(getent ahostsv4 "$MXT" 2>/dev/null | awk '{print $1}' | sort -u); do
        en_lista "$ip" "${ORIGIN_IPS[@]:-}" && { LOCAL_MX="si"; break; }
    done
    if [[ "$LOCAL_MX" == "no" ]]; then
        MXB=$(dominio_base "$MXT")
        while IFS=$'\t' read -r n t v; do
            [[ "$n" == "$zd" && "$t" == "NS" ]] || continue
            [[ "$(dominio_base "$v")" == "$MXB" ]] && { LOCAL_MX="si"; break; }
        done < "${ZONA_TSV[$zd]}"
    fi
    [[ "$LOCAL_MX" == "no" ]] && CORREO_EXTERNO["$zd"]="$MXT"
done
for zd in $(printf '%s\n' "${!ZONA_TSV[@]}" | sort); do
    if [[ -n "${CORREO_EXTERNO[$zd]:-}" ]]; then
        warn "Correo de $zd: EXTERNO (${CORREO_EXTERNO[$zd]}) -> no se crea correo local, se respetan MX y SPF"
    else
        info "Correo de $zd: local (en este servidor)"
    fi
done
# Correo externo para un subdominio = el de su zona
correo_externo_de() {
    local d="$1" z
    for z in "${!CORREO_EXTERNO[@]}"; do
        [[ "$d" == "$z" ]] && { echo "${CORREO_EXTERNO[$z]}"; return; }
    done
    echo ""
}

# ============================================================
#  INVENTARIO DE CORREO
# ============================================================
MAIL_BASE=""
for D in "$HOMEDIR/mail" "$BACKUP_PATH/mail"; do [[ -d "$D" ]] && { MAIL_BASE="$D"; break; }; done
VA_DIR="$BACKUP_PATH/va"
VAD_DIR="$BACKUP_PATH/vad"
CUENTA_DEFECTO_CON_CORREO="no"
if [[ -n "$MAIL_BASE" ]] && { [[ -n "$(ls -A "$MAIL_BASE/cur" 2>/dev/null)" ]] || [[ -n "$(ls -A "$MAIL_BASE/new" 2>/dev/null)" ]]; }; then
    CUENTA_DEFECTO_CON_CORREO="si"
fi

MAIL_DOMS_ALL=()
[[ -n "$MAIL_BASE" ]] && for d in "$MAIL_BASE"/*/; do
    d=$(basename "$d"); es_dominio "$d" && MAIL_DOMS_ALL+=("${d,,}")
done
for d in "$HOMEDIR"/etc/*/; do
    [[ -f "$d/passwd" || -f "$d/shadow" ]] || continue
    d=$(basename "$d"); es_dominio "$d" && MAIL_DOMS_ALL+=("${d,,}")
done
for f in "$VA_DIR"/* "$VAD_DIR"/*; do
    [[ -f "$f" ]] || continue
    d=$(basename "$f"); es_dominio "$d" || continue
    # Un va/ con solo la linea por defecto ("*: :fail:...") no aporta nada
    if [[ "$(dirname "$f")" == "$VA_DIR" ]] && ! grep -vqE '^[[:space:]]*(\*[[:space:]]*:[[:space:]]*:(fail|blackhole):.*)?[[:space:]]*$' "$f"; then
        continue
    fi
    MAIL_DOMS_ALL+=("${d,,}")
done
[[ "$CUENTA_DEFECTO_CON_CORREO" == "si" ]] && MAIL_DOMS_ALL+=("$MAIN_DOMAIN")
MAIL_DOMS_ALL=($(printf '%s\n' "${MAIL_DOMS_ALL[@]:-}" | grep -v '^$' | sort -u || true))

MAIL_DOMS=()
for d in "${MAIL_DOMS_ALL[@]:-}"; do
    [[ -z "$d" ]] && continue
    ext=$(correo_externo_de "$d")
    if [[ -n "$ext" ]]; then
        n=$( { cut -d: -f1 "$HOMEDIR/etc/$d/passwd" 2>/dev/null || true; } | grep -c . || true)
        if [[ "${n:-0}" -gt 0 ]]; then
            pendiente "$d tiene $n buzones en el backup pero su correo esta en $ext: NO se importan. Si el correo se va a mover aqui: QEMUCP_CORREO_LOCAL=$d"
        fi
        continue
    fi
    MAIL_DOMS+=("$d")
done

# ============================================================
#  COMPROBAR EL PLAN ANTES DE CREAR NADA
# ============================================================
header "Comprobando el plan '$PLAN'"
N_DBS=0
for D in "mysql" "mysql_databases" "mysql_dump"; do
    if [[ -d "$BACKUP_PATH/$D" ]]; then
        N_DBS=$(find "$BACKUP_PATH/$D" -maxdepth 1 \( -name '*.sql' -o -name '*.sql.gz' \) ! -name '*-auth*' | wc -l)
        break
    fi
done
CRON_FILE=""
for c in "$BACKUP_PATH/cron/$ORIG_USER" "$BACKUP_PATH/cron/crontab" "$BACKUP_PATH/cron"; do
    [[ -f "$c" ]] && { CRON_FILE="$c"; break; }
done
N_CRON=0
[[ -n "$CRON_FILE" ]] && N_CRON=$(grep -cE '^[[:space:]]*([0-9*@]|[0-9*/,-]+[[:space:]])' "$CRON_FILE" || true)
# Se cuenta igual que QemuCP (count_web_domains_split en func/main.sh): es
# subdominio lo que cuelga de OTRO dominio web de la cuenta. Un subdominio de
# un dominio aparcado (promo.aparcado.com) en QemuCP gasta un dominio, porque
# el aparcado es solo un alias.
N_TOP=0; N_SUB=0
for d in "${WEB_DOMAINS_ALL[@]}"; do
    es_sub="no"
    for p in "${WEB_DOMAINS_ALL[@]}"; do
        [[ "$d" != "$p" && "$d" == *".$p" ]] && { es_sub="si"; break; }
    done
    if [[ "$es_sub" == "si" ]]; then N_SUB=$((N_SUB+1)); else N_TOP=$((N_TOP+1)); fi
done
for s in "${SUB_DOMAINS[@]:-}"; do
    [[ -z "$s" ]] && continue
    for pk in "${PARKED_DOMAINS[@]:-}"; do
        [[ -n "$pk" && "$s" == *".$pk" ]] && { warn "$s es subdominio de un dominio aparcado: en QemuCP cuenta como dominio"; break; }
    done
done
N_MAILD=0; for s in "${MAIL_DOMS[@]:-}"; do [[ -n "$s" ]] && N_MAILD=$((N_MAILD+1)); done
N_ZONAS=${#ZONA_TSV[@]}
info "El backup necesita: $N_TOP dominios, $N_SUB subdominios, $N_DBS bases de datos, $N_MAILD dominios de correo, $N_ZONAS zonas DNS, $N_CRON crons"

USUARIO_EXISTE="no"
$BIN/v-list-user "$CPANEL_USER" &>/dev/null && USUARIO_EXISTE="si"
if [[ "$USUARIO_EXISTE" == "si" ]]; then
    warn "El usuario $CPANEL_USER ya existe: se importa sobre el (su plan no se cambia)"
else
    PKG="$HESTIA/data/packages/$PLAN.pkg"
    [[ -f "$PKG" ]] || error "El plan '$PLAN' no existe. Planes: $(ls $HESTIA/data/packages/ | sed 's/\.pkg$//' | tr '\n' ' ')"
    lim() { local v; v=$( { grep -m1 "^$1=" "$PKG" || true; } | cut -d"'" -f2); echo "${v:-unlimited}"; }
    FALTA=()
    chk() {  # nombre limite necesario
        [[ "$2" == "unlimited" ]] && return 0
        [[ "$3" -le "$2" ]] || FALTA+=("$1: el backup necesita $3 y el plan permite $2")
    }
    if grep -q "^WEB_SUBDOMAINS=" "$PKG"; then
        chk "Dominios" "$(lim WEB_DOMAINS)" "$N_TOP"
        chk "Subdominios" "$(lim WEB_SUBDOMAINS)" "$N_SUB"
    else
        chk "Dominios (incluye subdominios en este plan)" "$(lim WEB_DOMAINS)" "$((N_TOP + N_SUB))"
    fi
    chk "Bases de datos" "$(lim DATABASES)" "$N_DBS"
    chk "Dominios de correo" "$(lim MAIL_DOMAINS)" "$N_MAILD"
    chk "Zonas DNS" "$(lim DNS_DOMAINS)" "$N_ZONAS"
    chk "Crons" "$(lim CRON_JOBS)" "$N_CRON"
    if [[ ${#FALTA[@]} -gt 0 ]]; then
        for f in "${FALTA[@]}"; do warn "  $f"; done
        if [[ "${QEMUCP_IGNORAR_LIMITES:-no}" != "si" ]]; then
            error "El plan '$PLAN' se queda corto. Usa otro plan (tercer argumento) o QEMUCP_IGNORAR_LIMITES=si"
        fi
        warn "QEMUCP_IGNORAR_LIMITES=si: se continua; lo que no quepa no se creara"
    else
        log "El plan '$PLAN' cubre todo lo del backup"
    fi
fi

echo "" >> "$CREDS_FILE"
echo "=== Importacion $(date) - $CPANEL_USER ===" >> "$CREDS_FILE"
chmod 600 "$CREDS_FILE" 2>/dev/null || true

# -- Crear usuario en QemuCP ------------------------------------
header "Creando usuario en QemuCP"
if [[ "$USUARIO_EXISTE" == "no" ]]; then
    USER_PASS=$(openssl rand -base64 12 | tr -d '/+=')
    USER_EMAIL=$( { cat "$BACKUP_PATH/cp/contactemail" 2>/dev/null || true; } | head -1 | tr -d ' \r\n')
    [[ -z "$USER_EMAIL" && -f "$CP_USER_FILE" ]] && \
        USER_EMAIL=$( { grep -m1 "^CONTACTEMAIL=" "$CP_USER_FILE" || true; } | cut -d= -f2 | cut -d, -f1 | tr -d ' \r')
    if [[ -z "$USER_EMAIL" ]] || ! [[ "$USER_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
        USER_EMAIL="${CPANEL_USER}@${MAIN_DOMAIN}"
        warn "Email de contacto no encontrado, usando: $USER_EMAIL"
    fi
    $BIN/v-add-user "$CPANEL_USER" "$USER_PASS" "$USER_EMAIL" "$PLAN" >> "$LOG" 2>&1 \
        && log "Usuario $CPANEL_USER creado con el plan $PLAN" \
        || error "No se pudo crear el usuario $CPANEL_USER (ver $LOG)"
    echo "Usuario panel: $CPANEL_USER | Pass: $USER_PASS | Email: $USER_EMAIL | Plan: $PLAN" >> "$CREDS_FILE"
fi

# ============================================================
#  DOMINIOS WEB
# ============================================================
header "Creando dominios web"

SERVER_IP=$($BIN/v-list-sys-ips plain 2>/dev/null | awk '{print $1}' | grep -v "^$" | head -1 || true)
[[ -z "$SERVER_IP" ]] && SERVER_IP=$($BIN/v-list-ips plain 2>/dev/null | awk '{print $1}' | grep -v "^$" | head -1 || true)
[[ -z "$SERVER_IP" ]] && SERVER_IP=$(hostname -I | awk '{print $1}' || true)
[[ -z "$SERVER_IP" ]] && error "No se pudo detectar la IP del servidor"
# IP publica (si el servidor esta tras NAT, los DNS deben llevar la publica)
SERVER_IP_DNS="$SERVER_IP"
NAT_IP=$( { grep -m1 "^NAT=" "$HESTIA/data/ips/$SERVER_IP" 2>/dev/null || true; } | cut -d"'" -f2)
[[ -n "$NAT_IP" ]] && SERVER_IP_DNS="$NAT_IP"
log "IP del servidor: $SERVER_IP${NAT_IP:+ (publica $NAT_IP)}"

WEB_CREADOS=()
create_domain() {
    local domain="$1"
    if $BIN/v-list-web-domain "$CPANEL_USER" "$domain" &>/dev/null; then
        info "Dominio $domain ya existe"
        WEB_CREADOS+=("$domain")
    elif $BIN/v-add-web-domain "$CPANEL_USER" "$domain" "$SERVER_IP" "no" >> "$LOG" 2>&1; then
        log "Dominio $domain creado"
        WEB_CREADOS+=("$domain")
    else
        pendiente "No se pudo crear el dominio web $domain (ver $LOG: limite del plan o dominio en otra cuenta)"
    fi
}
create_domain "$MAIN_DOMAIN"
for D in "${ADDON_DOMAINS[@]:-}"; do [[ -n "$D" ]] && create_domain "$D"; done
for D in "${SUB_DOMAINS[@]:-}"; do [[ -n "$D" ]] && create_domain "$D"; done

# Dominios aparcados: alias del principal (con su www)
for PK in "${PARKED_DOMAINS[@]:-}"; do
    [[ -z "$PK" ]] && continue
    ALIAS_ACT=$( { grep "^DOMAIN='$MAIN_DOMAIN'" "$HESTIA/data/users/$CPANEL_USER/web.conf" 2>/dev/null || true; } \
                 | grep -oP "ALIAS='\K[^']*" || true)
    if csv_tiene "$ALIAS_ACT" "$PK"; then
        info "Alias $PK ya estaba en $MAIN_DOMAIN"
        continue
    fi
    $BIN/v-add-web-domain-alias "$CPANEL_USER" "$MAIN_DOMAIN" "$PK,www.$PK" no >> "$LOG" 2>&1 \
        && log "Alias de $MAIN_DOMAIN: $PK y www.$PK" \
        || pendiente "$PK: no se pudo anadir como alias de $MAIN_DOMAIN"
done

# ============================================================
#  FICHEROS WEB
# ============================================================
header "Importando ficheros web"
DEST_HOME="/home/$CPANEL_USER"

if [[ -d "$HOMEDIR" ]]; then
    for DOM in "${WEB_CREADOS[@]:-}"; do
        [[ -z "$DOM" ]] && continue
        SRC=$(ruta_backup "${DOCROOT_ORIG[$DOM]:-}")
        if [[ -z "$SRC" || ! -d "$SRC" ]]; then
            pendiente "No se encontro la carpeta web de $DOM en el backup (${DOCROOT_ORIG[$DOM]:-?})"
            continue
        fi
        DEST_DOM="$DEST_HOME/web/$DOM/public_html"
        mkdir -p "$DEST_DOM"
        rm -f "$DEST_DOM/index.html" "$DEST_DOM/robots.txt" 2>/dev/null || true
        # Las carpetas de otros dominios que cuelgan de esta (public_html/blog
        # es la web de blog.dominio.com) se copian a SU dominio, no aqui.
        EXCL=(--exclude='*.log' --exclude='.htaccess.bak' --exclude='error_log')
        for OTRO in "${WEB_CREADOS[@]}"; do
            [[ "$OTRO" == "$DOM" ]] && continue
            ODR="${DOCROOT_ORIG[$OTRO]:-}"; MDR="${DOCROOT_ORIG[$DOM]%/}"
            [[ -n "$ODR" && "$ODR" == "$MDR/"* ]] && EXCL+=(--exclude="/${ODR#$MDR/}")
        done
        if rsync -a "${EXCL[@]}" "$SRC/" "$DEST_DOM/" >> "$LOG" 2>&1; then
            log "Ficheros de $DOM copiados (desde ${SRC#$HOMEDIR/})"
        else
            pendiente "Error copiando ficheros de $DOM (ver $LOG)"
        fi
        chown -R "$CPANEL_USER:$CPANEL_USER" "$DEST_DOM" 2>/dev/null || true
        find "$DEST_DOM" -type d -exec chmod 755 {} + 2>/dev/null || true
        find "$DEST_DOM" -type f -exec chmod 644 {} + 2>/dev/null || true
    done
    # Enlace /home/USUARIO/public_html para apps con rutas fijas de cPanel
    if [[ ! -e "$DEST_HOME/public_html" ]]; then
        ln -s "$DEST_HOME/web/$MAIN_DOMAIN/public_html" "$DEST_HOME/public_html" 2>/dev/null \
            && log "Enlace /home/$CPANEL_USER/public_html creado" || true
    fi

    # Resto del home (carpetas fuera de las webs: scripts de cron, datos de
    # aplicaciones, librerias...). Se copia con la misma ruta, asi los crons
    # y las apps que usan /home/USUARIO/algo siguen funcionando.
    EXTRA_EXCL=(--exclude='/public_html' --exclude='/mail' --exclude='/etc' --exclude='/tmp'
        --exclude='/logs' --exclude='/access-logs' --exclude='/ssl' --exclude='/.cpanel'
        --exclude='/.trash' --exclude='/.htpasswds' --exclude='/.cagefs' --exclude='/.cl.selector'
        --exclude='/.softaculous' --exclude='/softaculous_backups' --exclude='/.cpaddons'
        --exclude='/perl5' --exclude='/.spamassassin' --exclude='/.razor' --exclude='/lscache'
        --exclude='/.lastlogin' --exclude='/.bash_history' --exclude='/www' --exclude='/web'
        --exclude='/conf' --exclude='/backup-*.tar.gz' --exclude='/cpmove-*.tar.gz'
        --exclude='/.ssh' --exclude='/.cache' --exclude='/.npm' --exclude='/.wp-cli'
        --exclude='/.autorespond' --exclude='/.contactemail' --exclude='/.zshrc')
    for DOM in "${WEB_CREADOS[@]:-}"; do
        ODR="${DOCROOT_ORIG[$DOM]:-}"; REL="${ODR#/home/$ORIG_USER/}"
        [[ -n "$REL" && "$REL" != "$ODR" ]] && EXTRA_EXCL+=(--exclude="/${REL%%/*}")
    done
    EXTRA_LIST="$WORK_DIR/home-extra.txt"
    # rsync aplicaria al propio /home/USUARIO los permisos del backup:
    # se guardan y se restauran (QemuCP los necesita como estan).
    HOME_OWN=$(stat -c '%u:%g' "$DEST_HOME"); HOME_MODE=$(stat -c '%a' "$DEST_HOME")
    rsync -a --out-format='%n' "${EXTRA_EXCL[@]}" "$HOMEDIR/" "$DEST_HOME/" > "$EXTRA_LIST" 2>> "$LOG" \
        || pendiente "Error copiando el resto del home (ver $LOG)"
    chown "$HOME_OWN" "$DEST_HOME"; chmod "$HOME_MODE" "$DEST_HOME"
    EXTRA_N=$(grep -vc '/$' "$EXTRA_LIST" || true)
    if [[ "${EXTRA_N:-0}" -gt 0 ]]; then
        log "Resto del home copiado ($EXTRA_N ficheros fuera de las webs)"
        awk -F/ 'NF && $1 != "." {print $1}' "$EXTRA_LIST" | sort -u | while read -r e; do
            case "$e" in web|mail|conf|tmp|.ssh|"") continue ;; esac
            [[ -e "$DEST_HOME/$e" ]] && chown -R "$CPANEL_USER:$CPANEL_USER" "$DEST_HOME/$e" 2>/dev/null || true
        done
    fi
else
    pendiente "No se encontro homedir/ en el backup: no hay ficheros web"
fi

# ---- .htaccess de cPanel ---------------------------------------
# cPanel mete en .htaccess directivas que en QemuCP (Apache + PHP-FPM) rompen
# la web:
#   AddHandler application/x-httpd-ea-php81 .php   -> el navegador DESCARGA
#                                                    los .php en vez de ejecutarlos
#   php_value / php_flag / suPHP_ConfigPath         -> error 500
# Se comentan (no se borran) y los php_value/php_flag pasan a .user.ini, que
# es donde PHP-FPM los lee. La version de PHP se detecta ANTES de esto.
declare -A PHP_DETECTADA=()
detect_php_version() {
    local DOMAIN="$1" WEBROOT="$2" V=""
    if [[ -f "$WEBROOT/.htaccess" ]]; then
        V=$( { grep -ioP "x-httpd-(ea-|alt-)?php[0-9]{2}" "$WEBROOT/.htaccess" || true; } | grep -oP "[0-9]{2}" | head -1)
    fi
    if [[ -z "$V" ]]; then
        for UD in "$BACKUP_PATH/userdata/$DOMAIN" "$BACKUP_PATH/userdata/${ADDON_LINK[$DOMAIN]:-none}"; do
            [[ -f "$UD" ]] || continue
            V=$( { grep -aiP "^phpversion" "$UD" || true; } | grep -oP "php[0-9]{2}" | grep -oP "[0-9]{2}" | head -1)
            [[ -n "$V" ]] && break
        done
    fi
    [[ -n "$V" && ${#V} -eq 2 ]] && echo "PHP-${V:0:1}_${V:1:1}" || echo ""
}
for DOM in "${WEB_CREADOS[@]:-}"; do
    [[ -z "$DOM" ]] && continue
    PHP_DETECTADA["$DOM"]=$(detect_php_version "$DOM" "$DEST_HOME/web/$DOM/public_html")
done

HT_FIX=0
while IFS= read -r -d '' HT; do
    if grep -qiE '^[[:space:]]*(AddHandler|AddType|SetHandler)[[:space:]]+application/x-httpd-(ea-|alt-)?php|^[[:space:]]*(php_value|php_flag|php_admin_value|php_admin_flag|suPHP_ConfigPath)[[:space:]]' "$HT"; then
        cp -p "$HT" "$HT.cpanel-orig"
        DIR=$(dirname "$HT")
        # php_value -> .user.ini (sin pisar lo que ya tenga)
        while read -r kind name val; do
            [[ -z "$name" ]] && continue
            val="${val%\"}"; val="${val#\"}"
            [[ "$kind" == *flag* ]] && { [[ "${val,,}" =~ ^(on|1|true)$ ]] && val="On" || val="Off"; }
            grep -qiE "^[[:space:]]*${name//./\\.}[[:space:]]*=" "$DIR/.user.ini" 2>/dev/null && continue
            echo "$name = $val" >> "$DIR/.user.ini"
        done < <(grep -iE '^[[:space:]]*php_(admin_)?(value|flag)[[:space:]]' "$HT" | awk '{k=tolower($1); n=$2; $1=""; $2=""; sub(/^[ \t]+/,""); print k, n, $0}')
        [[ -f "$DIR/.user.ini" ]] && chown "$CPANEL_USER:$CPANEL_USER" "$DIR/.user.ini" 2>/dev/null || true
        sed -i -E 's/^([[:space:]]*)((AddHandler|AddType|SetHandler)[[:space:]]+application\/x-httpd-(ea-|alt-)?php.*)$/\1# QemuCP (cPanel): \2/I;
                   s/^([[:space:]]*)((php_value|php_flag|php_admin_value|php_admin_flag|suPHP_ConfigPath)[[:space:]].*)$/\1# QemuCP (cPanel): \2/I' "$HT"
        chown "$CPANEL_USER:$CPANEL_USER" "$HT" "$HT.cpanel-orig" 2>/dev/null || true
        HT_FIX=$((HT_FIX+1))
    fi
done < <(find "$DEST_HOME/web" -name .htaccess -type f -print0 2>/dev/null)
[[ $HT_FIX -gt 0 ]] && log "$HT_FIX .htaccess adaptados (directivas de cPanel comentadas; original en .htaccess.cpanel-orig)"

# ============================================================
#  BASES DE DATOS
# ============================================================
header "Importando bases de datos MySQL"

MYSQL_DIR=""
for D in "mysql" "mysql_databases" "mysql_dump"; do
    [[ -d "$BACKUP_PATH/$D" ]] && MYSQL_DIR="$BACKUP_PATH/$D" && break
done

# Prefijos con los que cPanel nombra las bases de datos. Las versiones
# antiguas usaban solo los 8 primeros caracteres del usuario.
quitar_prefijo() {
    local n="$1" p
    for p in "${ORIG_USER}_" "${ORIG_USER:0:8}_" "${CPANEL_USER}_"; do
        [[ "$n" == "$p"* ]] && { echo "${n#$p}"; return; }
    done
    echo "$n"
}

MYSQL_CLI=$(command -v mariadb || command -v mysql || echo mysql)
if [[ -n "$MYSQL_DIR" ]]; then
    for SQL_FILE in "$MYSQL_DIR"/*.sql.gz "$MYSQL_DIR"/*.sql; do
        [[ -f "$SQL_FILE" ]] || continue
        [[ "$SQL_FILE" == *"-auth"* ]] && continue

        DB_BASENAME=$(basename "$SQL_FILE" .gz); DB_BASENAME=$(basename "$DB_BASENAME" .sql)
        DB_CLEAN=$(quitar_prefijo "$DB_BASENAME")
        DB_CLEAN=$(echo "$DB_CLEAN" | tr -c 'A-Za-z0-9_\n-' '_')
        DB_FINAL="${CPANEL_USER}_${DB_CLEAN}"
        DB_USER_FINAL="${CPANEL_USER}_${DB_CLEAN}"
        DB_PASS=$(openssl rand -base64 18 | tr -d '/+=' | head -c 20)
        info "DB: $DB_BASENAME -> $DB_FINAL"

        if ! $BIN/v-list-database "$CPANEL_USER" "$DB_FINAL" &>/dev/null; then
            if $BIN/v-add-database "$CPANEL_USER" "$DB_CLEAN" "$DB_CLEAN" "$DB_PASS" "mysql" "localhost" >> "$LOG" 2>&1; then
                log "  DB $DB_FINAL creada"
            else
                pendiente "No se pudo crear la base de datos $DB_FINAL (ver $LOG)"
                continue
            fi
        else
            warn "  DB $DB_FINAL ya existe: se vacia y se vuelve a importar del backup (contrasena nueva)"
            $BIN/v-change-database-password "$CPANEL_USER" "$DB_FINAL" "$DB_PASS" >> "$LOG" 2>&1 || true
            # Los permisos de MySQL van por nombre: borrar y crear la base de
            # datos los conserva. Sin esto, un dump sin DROP TABLE falla con
            # "Table already exists" al reimportar.
            $MYSQL_CLI -e "DROP DATABASE \`$DB_FINAL\`; CREATE DATABASE \`$DB_FINAL\`" >> "$LOG" 2>&1 \
                || pendiente "No se pudo vaciar $DB_FINAL para reimportarla"
        fi
        echo "DB: $DB_FINAL | User: $DB_USER_FINAL | Pass: $DB_PASS" >> "$CREDS_FILE"
        DB_CREATED+=("${DB_FINAL}:${DB_USER_FINAL}:${DB_PASS}")

        # DEFINER=`usuario_cpanel`@`localhost` en vistas, triggers y
        # procedimientos: ese usuario no existe aqui y fallan al usarse.
        # Sin DEFINER pasan a ser del usuario que importa.
        ERRF="$WORK_DIR/mysql-$DB_CLEAN.err"
        if { if [[ "$SQL_FILE" == *.gz ]]; then gunzip -c "$SQL_FILE"; else cat "$SQL_FILE"; fi; } \
            | sed -E 's/DEFINER=`[^`]+`@`[^`]+`//g; s/DEFINER=[^ *]+@[^ *]+//g' \
            | $MYSQL_CLI "$DB_FINAL" 2> "$ERRF"; then
            TABLAS=$($MYSQL_CLI -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB_FINAL'" 2>/dev/null || echo "?")
            log "  Datos importados en $DB_FINAL ($TABLAS tablas)"
        else
            pendiente "Error importando $DB_FINAL: $(head -c 200 "$ERRF")"
            cat "$ERRF" >> "$LOG"
        fi
    done
else
    info "El backup no tiene bases de datos"
fi

# ============================================================
#  CORREO
# ============================================================
header "Importando correo"

# Guarda el hash ORIGINAL de la contrasena. Hay que escribirlo en el registro
# de la cuenta (campo MD5 de mail/DOMINIO.conf), no solo en el fichero passwd:
# cualquier reconstruccion (v-rebuild-user, una actualizacion del panel...)
# regenera passwd desde ese campo. Antes solo se tocaba passwd y el propio
# rebuild del final del migrador lo sustituia por una contrasena aleatoria
# que no se apuntaba en ningun sitio: "la contrasena deja de funcionar sola".
hash_dovecot() {
    case "$1" in
        '$6$'*) echo "{SHA512-CRYPT}$1" ;;
        '$5$'*) echo "{SHA256-CRYPT}$1" ;;
        '$1$'*) echo "{MD5-CRYPT}$1" ;;
        '$2y$'*|'$2b$'*|'$2a$'*) echo "{BLF-CRYPT}$1" ;;
        '$argon2id$'*) echo "{ARGON2ID}$1" ;;
        *) echo "{CRYPT}$1" ;;
    esac
}
set_mail_hash() {  # dominio cuenta hash_cpanel
    local dom="$1" acc="$2" h conf pw
    h=$(hash_dovecot "$3")
    [[ "$h" == *"'"* || "$h" == *"&"* || "$h" == *"\\"* ]] && return 1
    conf="$HESTIA/data/users/$CPANEL_USER/mail/$dom.conf"
    pw="$DEST_HOME/conf/mail/$dom/passwd"
    [[ -f "$conf" ]] || return 1
    awk -v a="$acc" -v h="$h" 'index($0, "ACCOUNT=\047" a "\047") == 1 { sub(/MD5=\047[^\047]*\047/, "MD5=\047" h "\047") } { print }' \
        "$conf" > "$conf.qtmp" && cat "$conf.qtmp" > "$conf" && rm -f "$conf.qtmp"
    if [[ -f "$pw" ]]; then
        awk -F: -v OFS=: -v a="$acc" -v h="$h" '$1 == a { $2 = h } { print }' "$pw" > "$pw.qtmp" \
            && cat "$pw.qtmp" > "$pw" && rm -f "$pw.qtmp"
    fi
    grep -qF "MD5='$h'" "$conf"
}
cuenta_existe() { $BIN/v-list-mail-account "$CPANEL_USER" "$1" "$2" &>/dev/null; }
crear_cuenta() {  # dominio cuenta -> 0 si existe o se crea
    local dom="$1" acc="$2" p
    cuenta_existe "$dom" "$acc" && return 0
    p=$(openssl rand -base64 18 | tr -d '/+=' | head -c 16)
    if $BIN/v-add-mail-account "$CPANEL_USER" "$dom" "$acc" "$p" >> "$LOG" 2>&1; then
        ULTIMA_PASS="$p"; return 0
    fi
    return 1
}
permisos_correo() {  # dominio
    local dom="$1" MF
    local MAILCONF_DIR="$DEST_HOME/conf/mail/$dom"
    # Patron de QemuCP: directorio Debian-exim:mail 771, passwd dovecot:mail
    # 660, resto Debian-exim:mail 660. Si no, Dovecot rechaza los logins y
    # Exim devuelve el correo entrante con 451.
    if [[ -d "$MAILCONF_DIR" ]]; then
        chown Debian-exim:mail "$MAILCONF_DIR" 2>/dev/null || true
        chmod 771 "$MAILCONF_DIR" 2>/dev/null || true
        for MF in "$MAILCONF_DIR"/*; do
            [[ -f "$MF" ]] || continue
            case "$(basename "$MF")" in
                passwd) chown dovecot:mail "$MF" 2>/dev/null || true; chmod 660 "$MF" 2>/dev/null || true ;;
                *.conf|*.conf_letsencrypt) ;;
                *) chown Debian-exim:mail "$MF" 2>/dev/null || true; chmod 660 "$MF" 2>/dev/null || true ;;
            esac
        done
    fi
    if [[ -d "$DEST_HOME/mail/$dom" ]]; then
        chown -R "$CPANEL_USER:mail" "$DEST_HOME/mail/$dom" 2>/dev/null || true
        find "$DEST_HOME/mail/$dom" -type d -exec chmod 770 {} + 2>/dev/null || true
        find "$DEST_HOME/mail/$dom" -type f -exec chmod 660 {} + 2>/dev/null || true
    fi
}

N_CUENTAS=0; N_FWD=0; N_PASS_ORIG=0
DEFAULT_ADDR=""
for MAIL_DOMAIN in "${MAIL_DOMS[@]:-}"; do
    [[ -z "$MAIL_DOMAIN" ]] && continue
    info "Dominio de correo: $MAIL_DOMAIN"
    if ! $BIN/v-list-mail-domain "$CPANEL_USER" "$MAIL_DOMAIN" &>/dev/null; then
        if $BIN/v-add-mail-domain "$CPANEL_USER" "$MAIL_DOMAIN" >> "$LOG" 2>&1; then
            log "  Dominio de correo $MAIL_DOMAIN creado"
        else
            pendiente "No se pudo crear el dominio de correo $MAIL_DOMAIN (ver $LOG)"
            continue
        fi
    fi

    ETC_DOM="$HOMEDIR/etc/$MAIL_DOMAIN"
    declare -A SHADOW_HASHES=()
    if [[ -f "$ETC_DOM/shadow" ]]; then
        while IFS=: read -r acc hash _rest; do
            [[ -z "$acc" || -z "$hash" || "$hash" == "!!" || "$hash" == "*" || "$hash" == "!"* ]] && continue
            SHADOW_HASHES["$acc"]="$hash"
        done < "$ETC_DOM/shadow"
    fi
    declare -A CUOTAS=()
    if [[ -f "$ETC_DOM/quota" ]]; then
        while IFS=: read -r acc bytes; do
            [[ -n "$acc" && "$bytes" =~ ^[0-9]+$ && "$bytes" -gt 0 ]] && CUOTAS["$acc"]=$(( (bytes + 1048575) / 1048576 ))
        done < "$ETC_DOM/quota"
    fi

    # Cuentas: las del fichero passwd de cPanel (incluye las que nunca han
    # recibido correo y no tienen carpeta) mas las carpetas de buzon.
    CUENTAS=()
    [[ -f "$ETC_DOM/passwd" ]] && while IFS=: read -r acc _r; do [[ -n "$acc" ]] && CUENTAS+=("${acc,,}"); done < "$ETC_DOM/passwd"
    if [[ -n "$MAIL_BASE" && -d "$MAIL_BASE/$MAIL_DOMAIN" ]]; then
        for ad in "$MAIL_BASE/$MAIL_DOMAIN"/*/; do
            [[ -d "$ad" ]] || continue
            a=$(basename "$ad"); [[ "$a" == .* || "$a" =~ ^(cur|new|tmp)$ ]] && continue
            CUENTAS+=("${a,,}")
        done
    fi
    CUENTAS=($(printf '%s\n' "${CUENTAS[@]:-}" | grep -E '^[a-z0-9._+-]+$' | sort -u || true))

    for ACCOUNT in "${CUENTAS[@]:-}"; do
        [[ -z "$ACCOUNT" ]] && continue
        NUEVA="no"; cuenta_existe "$MAIL_DOMAIN" "$ACCOUNT" || NUEVA="si"
        ULTIMA_PASS=""
        if ! crear_cuenta "$MAIL_DOMAIN" "$ACCOUNT"; then
            pendiente "No se pudo crear $ACCOUNT@$MAIL_DOMAIN (ver $LOG)"
            continue
        fi
        N_CUENTAS=$((N_CUENTAS+1))
        if [[ -n "${SHADOW_HASHES[$ACCOUNT]:-}" ]] && set_mail_hash "$MAIL_DOMAIN" "$ACCOUNT" "${SHADOW_HASHES[$ACCOUNT]}"; then
            N_PASS_ORIG=$((N_PASS_ORIG+1))
            info "  $ACCOUNT@$MAIL_DOMAIN (contrasena original)"
        elif [[ "$NUEVA" == "si" ]]; then
            echo "Mail: $ACCOUNT@$MAIL_DOMAIN | Pass: $ULTIMA_PASS (nueva)" >> "$CREDS_FILE"
            pendiente "$ACCOUNT@$MAIL_DOMAIN sin contrasena en el backup: se ha puesto una nueva (en $CREDS_FILE)"
        fi
        if [[ -n "${CUOTAS[$ACCOUNT]:-}" ]]; then
            $BIN/v-change-mail-account-quota "$CPANEL_USER" "$MAIL_DOMAIN" "$ACCOUNT" "${CUOTAS[$ACCOUNT]}" >> "$LOG" 2>&1 || true
        fi
        SRC_MAIL="$MAIL_BASE/$MAIL_DOMAIN/$ACCOUNT"
        DEST_MAIL="$DEST_HOME/mail/$MAIL_DOMAIN/$ACCOUNT"
        if [[ -n "$MAIL_BASE" && -d "$SRC_MAIL" ]]; then
            mkdir -p "$DEST_MAIL"
            if [[ -d "$SRC_MAIL/storage" ]] && ls "$SRC_MAIL/storage"/m.* >/dev/null 2>&1; then
                # cPanel puede guardar los buzones en mdbox; QemuCP usa maildir
                MDB_OK="no"
                if command -v doveadm >/dev/null 2>&1; then
                    mkdir -p "$DEST_MAIL"; chown -R "$CPANEL_USER:mail" "$DEST_MAIL"
                    # Importa del mdbox del backup al buzon (maildir) de la cuenta
                    doveadm import -s -u "$ACCOUNT@$MAIL_DOMAIN" "mdbox:$SRC_MAIL" "" all >> "$LOG" 2>&1 && MDB_OK="si"
                fi
                [[ "$MDB_OK" == "si" ]] && info "  $ACCOUNT@$MAIL_DOMAIN: buzon mdbox convertido" \
                    || pendiente "$ACCOUNT@$MAIL_DOMAIN esta en formato mdbox y no se pudo convertir: migrarlo con imapsync"
            else
                rsync -a "$SRC_MAIL/" "$DEST_MAIL/" >> "$LOG" 2>&1 || pendiente "Error copiando el buzon de $ACCOUNT@$MAIL_DOMAIN"
            fi
        fi
    done
    unset SHADOW_HASHES CUOTAS

    # Cuenta por defecto de cPanel (usuario@dominio principal): sus mensajes
    # estan directamente en mail/{cur,new,tmp} y carpetas mail/.Sent, etc.
    if [[ "$MAIL_DOMAIN" == "$MAIN_DOMAIN" && "$CUENTA_DEFECTO_CON_CORREO" == "si" ]]; then
        ULTIMA_PASS=""
        NUEVA="no"; cuenta_existe "$MAIN_DOMAIN" "$ORIG_USER" || NUEVA="si"
        if crear_cuenta "$MAIN_DOMAIN" "$ORIG_USER"; then
            DEFAULT_ADDR="$ORIG_USER@$MAIN_DOMAIN"
            N_CUENTAS=$((N_CUENTAS+1))
            mkdir -p "$DEST_HOME/mail/$MAIN_DOMAIN/$ORIG_USER"
            rsync -a --include='/cur/***' --include='/new/***' --include='/tmp/***' --include='/.*/***' \
                --include='/dovecot-uidlist' --include='/dovecot-uidvalidity*' --exclude='*' \
                "$MAIL_BASE/" "$DEST_HOME/mail/$MAIN_DOMAIN/$ORIG_USER/" >> "$LOG" 2>&1 || true
            SYS_HASH=""
            if [[ -f "$BACKUP_PATH/shadow" ]]; then
                SYS_HASH=$(head -1 "$BACKUP_PATH/shadow" | tr -d '\r\n')
                [[ "$SYS_HASH" == *:* ]] && SYS_HASH=$(echo "$SYS_HASH" | cut -d: -f2)
            fi
            if [[ "$SYS_HASH" == '$'* ]] && set_mail_hash "$MAIN_DOMAIN" "$ORIG_USER" "$SYS_HASH"; then
                log "  Cuenta por defecto $DEFAULT_ADDR (contrasena de cPanel)"
            elif [[ "$NUEVA" == "si" ]]; then
                echo "Mail: $DEFAULT_ADDR | Pass: $ULTIMA_PASS (cuenta por defecto, nueva)" >> "$CREDS_FILE"
                pendiente "Cuenta por defecto $DEFAULT_ADDR creada con contrasena nueva (en $CREDS_FILE)"
            fi
        fi
    fi
done

# Destino de un reenvio en formato cPanel -> direccion (o vacio si no aplica)
destino_reenvio() {  # destino dominio
    local x="$1" dom="$2"
    x="${x#"${x%%[![:space:]]*}"}"; x="${x%"${x##*[![:space:]]}"}"; x="${x%\"}"; x="${x#\"}"
    case "$x" in
        ""|:fail:*|:blackhole:*) echo "" ;;
        \|*|/*) echo "PIPE" ;;
        *@*) echo "${x,,}" ;;
        *) if [[ "${x,,}" == "$ORIG_USER" ]]; then echo "${DEFAULT_ADDR:-DEFAULT}"; else echo "${x,,}@$dom"; fi ;;
    esac
}

# Reenviadores: va/DOMINIO (formato "cuenta@dominio: destino1,destino2")
# y, por compatibilidad, homedir/etc/DOMINIO/aliases.
for MAIL_DOMAIN in "${MAIL_DOMS[@]:-}"; do
    [[ -z "$MAIL_DOMAIN" ]] && continue
    $BIN/v-list-mail-domain "$CPANEL_USER" "$MAIL_DOMAIN" &>/dev/null || continue
    CATCHALL=""
    for VAF in "$VA_DIR/$MAIL_DOMAIN" "$HOMEDIR/etc/$MAIL_DOMAIN/aliases"; do
        [[ -f "$VAF" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            line="${line%$'\r'}"
            [[ -z "${line// }" || "$line" =~ ^[[:space:]]*# ]] && continue
            [[ "$line" == *:* ]] || continue
            lhs="${line%%:*}"; rhs="${line#*:}"
            lhs=$(echo "$lhs" | tr -d ' \t'); lhs="${lhs,,}"
            if [[ "$lhs" == "*" || "$lhs" == "*@$MAIL_DOMAIN" ]]; then CATCHALL="$rhs"; continue; fi
            lhs="${lhs%@$MAIL_DOMAIN}"
            [[ "$lhs" == *@* ]] && continue
            [[ "$lhs" =~ ^[a-z0-9._+-]+$ ]] || { pendiente "Reenviador no valido en $MAIL_DOMAIN: $line"; continue; }
            DESTS=()
            IFS=',' read -ra PARTES <<< "$rhs"
            for x in "${PARTES[@]}"; do
                d=$(destino_reenvio "$x" "$MAIL_DOMAIN")
                case "$d" in
                    "") ;;
                    PIPE) pendiente "Reenvio a programa no migrable: $lhs@$MAIL_DOMAIN -> $x" ;;
                    DEFAULT) pendiente "$lhs@$MAIL_DOMAIN reenviaba a la cuenta por defecto de cPanel, que no tiene correo" ;;
                    "$lhs@$MAIL_DOMAIN") ;;
                    *) DESTS+=("$d") ;;
                esac
            done
            [[ ${#DESTS[@]} -eq 0 ]] && continue
            TENIA_BUZON="si"; cuenta_existe "$MAIL_DOMAIN" "$lhs" || TENIA_BUZON="no"
            if ! crear_cuenta "$MAIL_DOMAIN" "$lhs"; then
                pendiente "No se pudo crear el reenviador $lhs@$MAIL_DOMAIN"
                continue
            fi
            for d in "${DESTS[@]}"; do
                $BIN/v-add-mail-account-forward "$CPANEL_USER" "$MAIL_DOMAIN" "$lhs" "$d" >> "$LOG" 2>&1 \
                    && N_FWD=$((N_FWD+1)) || true
            done
            # Reenviador puro de cPanel (sin buzon): solo reenvia, no guarda copia
            if [[ "$TENIA_BUZON" == "no" ]]; then
                $BIN/v-add-mail-account-fwd-only "$CPANEL_USER" "$MAIL_DOMAIN" "$lhs" >> "$LOG" 2>&1 || true
            fi
        done < "$VAF"
    done
    if [[ -n "$CATCHALL" ]]; then
        d=$(destino_reenvio "${CATCHALL%%,*}" "$MAIL_DOMAIN")
        case "$d" in
            ""|PIPE) ;;
            DEFAULT) pendiente "Catch-all de $MAIL_DOMAIN iba a la cuenta por defecto de cPanel (sin correo): no se configura" ;;
            *) $BIN/v-add-mail-domain-catchall "$CPANEL_USER" "$MAIL_DOMAIN" "$d" >> "$LOG" 2>&1 \
                   && log "  Catch-all de $MAIL_DOMAIN -> $d" || pendiente "No se pudo poner el catch-all de $MAIL_DOMAIN -> $d" ;;
        esac
    fi
done

# Reenviadores de DOMINIO (vad/ALIAS contiene el dominio destino): todo el
# correo de alias.com va a la misma cuenta en destino.com. QemuCP no tiene
# alias de dominio de correo: se crea en alias.com cada cuenta de destino.com
# como solo-reenvio, y el mismo catch-all.
if [[ -d "$VAD_DIR" ]]; then
    for VF in "$VAD_DIR"/*; do
        [[ -f "$VF" ]] || continue
        ALIAS_DOM=$(basename "${VF,,}")
        DEST_DOM=$( { grep -v '^[[:space:]]*$' "$VF" || true; } | head -1 | tr -d '\r')
        DEST_DOM="${DEST_DOM##*:}"; DEST_DOM=$(echo "${DEST_DOM,,}" | tr -d ' \t')
        es_dominio "$DEST_DOM" || continue
        $BIN/v-list-mail-domain "$CPANEL_USER" "$ALIAS_DOM" &>/dev/null || continue
        if ! $BIN/v-list-mail-domain "$CPANEL_USER" "$DEST_DOM" &>/dev/null; then
            pendiente "$ALIAS_DOM reenviaba todo a $DEST_DOM, que no tiene correo en este servidor"
            continue
        fi
        NA=0
        for acc in $(grep -oP "^ACCOUNT='\K[^']+" "$HESTIA/data/users/$CPANEL_USER/mail/$DEST_DOM.conf" 2>/dev/null); do
            cuenta_existe "$ALIAS_DOM" "$acc" && continue
            crear_cuenta "$ALIAS_DOM" "$acc" || continue
            $BIN/v-add-mail-account-forward "$CPANEL_USER" "$ALIAS_DOM" "$acc" "$acc@$DEST_DOM" >> "$LOG" 2>&1 || true
            $BIN/v-add-mail-account-fwd-only "$CPANEL_USER" "$ALIAS_DOM" "$acc" >> "$LOG" 2>&1 || true
            NA=$((NA+1))
        done
        CA=$( { grep "DOMAIN='$DEST_DOM'" "$HESTIA/data/users/$CPANEL_USER/mail.conf" 2>/dev/null || true; } \
              | grep -oP "CATCHALL='\K[^']*" || true)
        [[ -n "$CA" ]] && $BIN/v-add-mail-domain-catchall "$CPANEL_USER" "$ALIAS_DOM" "$CA" >> "$LOG" 2>&1 || true
        log "  Alias de dominio de correo: $ALIAS_DOM -> $DEST_DOM ($NA direcciones)"
    done
fi

for MAIL_DOMAIN in "${MAIL_DOMS[@]:-}"; do [[ -n "$MAIL_DOMAIN" ]] && permisos_correo "$MAIL_DOMAIN"; done
[[ ${#MAIL_DOMS[@]} -gt 0 && -n "${MAIL_DOMS[0]:-}" ]] && \
    log "Correo: $N_CUENTAS cuentas ($N_PASS_ORIG con su contrasena original), $N_FWD reenvios"

# Lo que no se puede migrar automaticamente
if [[ -d "$HOMEDIR/.autorespond" ]] && [[ -n "$(ls -A "$HOMEDIR/.autorespond" 2>/dev/null)" ]]; then
    pendiente "Hay respuestas automaticas en cPanel ($(ls "$HOMEDIR/.autorespond" | grep -c . || true)): crearlas a mano en el panel"
fi
if [[ -d "$BACKUP_PATH/vf" ]]; then
    for f in "$BACKUP_PATH"/vf/*; do
        [[ -s "$f" ]] && grep -qvE '^[[:space:]]*(#.*)?$' "$f" && pendiente "Filtros de correo de cPanel en $(basename "$f"): recrearlos a mano"
    done
fi

# ============================================================
#  CRON
# ============================================================
header "Importando tareas programadas (cron)"

# Rutas del origen -> rutas en QemuCP (la mas larga primero)
CRON_MAP="$WORK_DIR/cron-map.txt"
: > "$CRON_MAP"
for DOM in "${WEB_CREADOS[@]:-}"; do
    [[ -z "$DOM" || -z "${DOCROOT_ORIG[$DOM]:-}" ]] && continue
    printf '%s\t%s\n' "${DOCROOT_ORIG[$DOM]%/}" "/home/$CPANEL_USER/web/$DOM/public_html" >> "$CRON_MAP"
done
cron_rutas() {
    local c="$1" o n
    while IFS=$'\t' read -r o n; do
        c="${c//"$o"/"$n"}"
    done < <(awk -F'\t' '{print length($1) "\t" $0}' "$CRON_MAP" | sort -rn | cut -f2-)
    [[ "$ORIG_USER" != "$CPANEL_USER" ]] && c="${c//"/home/$ORIG_USER/"//home/$CPANEL_USER/}"
    # PHP de cPanel (EasyApache) -> PHP de este servidor
    c=$(echo "$c" | sed -E 's#/opt/cpanel/ea-php([0-9])([0-9])/root/usr/bin/php(-cli)?#/usr/bin/php\1.\2#g;
                             s#/usr/local/bin/ea-php([0-9])([0-9])#/usr/bin/php\1.\2#g;
                             s#/usr/local/bin/php(-cli)?([[:space:]]|$)#/usr/bin/php\2#g;
                             s#/usr/bin/php-cli([[:space:]]|$)#/usr/bin/php\1#g')
    while [[ "$c" =~ /usr/bin/php([0-9]\.[0-9]) ]]; do
        [[ -x "/usr/bin/php${BASH_REMATCH[1]}" ]] && break
        c="${c//"/usr/bin/php${BASH_REMATCH[1]}"//usr/bin/php}"
    done
    # Hestia no admite comillas invertidas: `cmd` -> $(cmd)
    c=$(echo "$c" | sed 's/`\([^`]*\)`/$(\1)/g')
    echo "$c"
}
nombres_cron() {  # mon,tue -> 1,2   jan -> 1
    echo "$1" | sed -E 's/\b[Ss][Uu][Nn]\b/0/g; s/\b[Mm][Oo][Nn]\b/1/g; s/\b[Tt][Uu][Ee]\b/2/g; s/\b[Ww][Ee][Dd]\b/3/g;
        s/\b[Tt][Hh][Uu]\b/4/g; s/\b[Ff][Rr][Ii]\b/5/g; s/\b[Ss][Aa][Tt]\b/6/g;
        s/\b[Jj][Aa][Nn]\b/1/g; s/\b[Ff][Ee][Bb]\b/2/g; s/\b[Mm][Aa][Rr]\b/3/g; s/\b[Aa][Pp][Rr]\b/4/g;
        s/\b[Mm][Aa][Yy]\b/5/g; s/\b[Jj][Uu][Nn]\b/6/g; s/\b[Jj][Uu][Ll]\b/7/g; s/\b[Aa][Uu][Gg]\b/8/g;
        s/\b[Ss][Ee][Pp]\b/9/g; s/\b[Oo][Cc][Tt]\b/10/g; s/\b[Nn][Oo][Vv]\b/11/g; s/\b[Dd][Ee][Cc]\b/12/g'
}

if [[ -n "$CRON_FILE" ]]; then
    CRON_OK=0; CRON_SKIP=0; CRON_YA=0
    CRON_CONF="$HESTIA/data/users/$CPANEL_USER/cron.conf"
    while IFS= read -r linea || [[ -n "$linea" ]]; do
        linea="${linea%$'\r'}"
        [[ -z "${linea// }" ]] && continue
        [[ "$linea" =~ ^[[:space:]]*# ]] && continue
        [[ "$linea" =~ ^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*= ]] && continue
        linea="${linea#"${linea%%[![:space:]]*}"}"
        case "$linea" in
            @reboot*) pendiente "Cron @reboot no migrado: ${linea:0:80}"; CRON_SKIP=$((CRON_SKIP+1)); continue ;;
            @yearly*|@annually*) linea="0 0 1 1 * ${linea#* }" ;;
            @monthly*) linea="0 0 1 * * ${linea#* }" ;;
            @weekly*) linea="0 0 * * 0 ${linea#* }" ;;
            @daily*|@midnight*) linea="0 0 * * * ${linea#* }" ;;
            @hourly*) linea="0 * * * * ${linea#* }" ;;
        esac
        read -r MIN HOR DIA MES WDY CMD <<< "$linea"
        MES=$(nombres_cron "$MES"); WDY=$(nombres_cron "$WDY")
        if [[ -z "${CMD:-}" ]] || ! [[ "$MIN$HOR$DIA$MES$WDY" =~ ^[0-9*/,-]+$ ]]; then
            pendiente "Cron no reconocido: ${linea:0:80}"; CRON_SKIP=$((CRON_SKIP+1)); continue
        fi
        if [[ "$CMD" == *"/usr/local/cpanel"* || "$CMD" =~ (^|[[:space:]])/scripts/ ]]; then
            pendiente "Cron de cPanel no migrable: ${CMD:0:80}"; CRON_SKIP=$((CRON_SKIP+1)); continue
        fi
        CMD=$(cron_rutas "$CMD")
        # Reejecutar el migrador no duplica crons
        if [[ -f "$CRON_CONF" ]] && grep -qF "CMD='${CMD//\'/%quote%}'" "$CRON_CONF"; then
            CRON_YA=$((CRON_YA+1)); continue
        fi
        if $BIN/v-add-cron-job "$CPANEL_USER" "$MIN" "$HOR" "$DIA" "$MES" "$WDY" "$CMD" >> "$LOG" 2>&1; then
            CRON_OK=$((CRON_OK+1))
        else
            CRON_SKIP=$((CRON_SKIP+1))
            pendiente "No se pudo crear el cron: $MIN $HOR $DIA $MES $WDY ${CMD:0:60}"
        fi
    done < "$CRON_FILE"
    log "Crons: $CRON_OK importados, $CRON_YA ya existian, $CRON_SKIP omitidos"
else
    info "El backup no tiene crons"
fi

# ============================================================
#  DNS
# ============================================================
header "Importando DNS"

zona_escribir() {  # conf nombre tipo prioridad valor  (sin duplicar)
    local conf="$1" rn="$2" t="$3" pr="$4" v="$5" nid
    v="${v//\'/%quote%}"
    grep -qF "RECORD='$rn' TYPE='$t' PRIORITY='$pr' VALUE='$v'" "$conf" 2>/dev/null && return 1
    nid=$(( $( { grep -oP "^ID='\K[0-9]+" "$conf" || echo 0; } | sort -n | tail -1) + 1 ))
    printf "ID='%s' RECORD='%s' TYPE='%s' PRIORITY='%s' VALUE='%s' SUSPENDED='no' TIME='%s' DATE='%s'\n" \
        "$nid" "$rn" "$t" "$pr" "$v" "$(date +%T)" "$(date +%F)" >> "$conf"
}
zona_borrar() {  # conf patron-de-linea (texto literal)
    local conf="$1" pat="$2"
    grep -vF -- "$pat" "$conf" > "$conf.qtmp" || true
    cat "$conf.qtmp" > "$conf"; rm -f "$conf.qtmp"
}

declare -A ZONA_CREADA=()
for ZD in $(printf '%s\n' "${!ZONA_TSV[@]}" | sort); do
    TSV="${ZONA_TSV[$ZD]}"
    ZONE_CONF="$HESTIA/data/users/$CPANEL_USER/dns/${ZD}.conf"
    if ! $BIN/v-list-dns-domain "$CPANEL_USER" "$ZD" &>/dev/null; then
        if $BIN/v-add-dns-domain "$CPANEL_USER" "$ZD" "$SERVER_IP_DNS" '' '' '' '' '' '' '' '' 'no' >> "$LOG" 2>&1; then
            log "Zona DNS $ZD creada"
        else
            pendiente "No se pudo crear la zona DNS $ZD (ver $LOG)"
            continue
        fi
    else
        info "Zona DNS $ZD ya existe"
    fi
    [[ -f "$ZONE_CONF" ]] || continue
    ZONA_CREADA["$ZD"]=1
    EXT="${CORREO_EXTERNO[$ZD]:-}"
    SPF_CLIENTE=""; DMARC_CLIENTE=""; APEX_EXTERNA=""; CAA_ISSUE=(); REC_COUNT=0

    # Correo externo: fuera los registros de correo de la PLANTILLA de QemuCP
    # antes de importar los del cliente (si el cliente tenia uno igual, se
    # vuelve a escribir al importar). Despues no se puede distinguir cual es
    # de la plantilla y cual del cliente.
    if [[ -n "$EXT" ]]; then
        zona_borrar "$ZONE_CONF" "RECORD='@' TYPE='MX' PRIORITY='0' VALUE='mail.${ZD}.'"
        for s in _submission._tcp _imap._tcp _imaps._tcp _pop3._tcp _pop3s._tcp; do
            sed -i "/RECORD='$s' TYPE='SRV' .*VALUE='[0-9]* [0-9]* mail\.${ZD//./\\.}\.'/d" "$ZONE_CONF"
        done
        if awk -F'\t' -v h="mail.$ZD" '$1 == h { f = 1 } END { exit !f }' "$TSV"; then
            zona_borrar "$ZONE_CONF" "RECORD='mail' TYPE='A' PRIORITY='' VALUE='$SERVER_IP_DNS'"
        fi
        if awk -F'\t' -v h="webmail.$ZD" '$1 == h { f = 1 } END { exit !f }' "$TSV"; then
            zona_borrar "$ZONE_CONF" "RECORD='webmail' TYPE='CNAME' PRIORITY='' VALUE='mail.${ZD}.'"
        fi
    fi

    while IFS=$'\t' read -r n t v; do
        case "$t" in A|AAAA|CNAME|MX|TXT|SRV|CAA|NS) ;; *) continue ;; esac
        if [[ "$n" == "$ZD" ]]; then rn="@"
        elif [[ "$n" == *".$ZD" ]]; then rn="${n%.$ZD}"
        else continue; fi
        # Registros propios de cPanel: apuntan al servidor de origen y no
        # existen en QemuCP. El DKIM antiguo haria fallar la firma de aqui.
        case "$rn" in
            whm|cpanel|webdisk|cpcontacts|cpcalendars|autodiscover|autoconfig|localhost) continue ;;
            whm.*|cpanel.*|webdisk.*|cpcontacts.*|cpcalendars.*|autodiscover.*|autoconfig.*) continue ;;
            _cpanel-dcv-test-record*|_acme-challenge*|_caldav*|_carddav*|_autodiscover*) continue ;;
            *_domainkey*) continue ;;
        esac
        pr=""
        case "$t" in
            NS) [[ "$rn" == "@" ]] && continue ;;
            A)
                if [[ "$rn" == "@" ]]; then
                    en_lista "$v" "${ORIGIN_IPS[@]:-}" || APEX_EXTERNA="$v"
                    continue
                fi
                en_lista "$v" "${ORIGIN_IPS[@]:-}" && v="$SERVER_IP_DNS"
                ;;
            AAAA)
                [[ "$rn" == "@" ]] && continue
                en_lista "${v,,}" "${ORIGIN_IP6[@]:-}" && continue
                ;;
            MX)
                # Con correo local manda el MX de QemuCP (mail.dominio); los del
                # origen competirian con el. Con correo externo se respetan.
                [[ -z "$EXT" ]] && continue
                pr="${v%% *}"; v="${v#* }"
                [[ "$pr" =~ ^[0-9]+$ ]] || continue
                ;;
            SRV)
                pr="${v%% *}"; v="${v#* }"
                [[ "$pr" =~ ^[0-9]+$ ]] || continue
                ;;
            TXT)
                v="${v//\\;/;}"
                if [[ "$rn" == "@" && "$v" == *"v=spf1"* ]]; then SPF_CLIENTE="$v"; continue; fi
                if [[ "$rn" == "_dmarc" ]]; then DMARC_CLIENTE="$v"; continue; fi
                ;;
            CAA)
                [[ "$v" == *issue* ]] && CAA_ISSUE+=("$v")
                ;;
        esac
        [[ -z "$v" ]] && continue
        # CNAME con valor relativo al dominio -> absoluto con punto final
        [[ "$t" =~ ^(CNAME|NS|MX)$ ]] && v="${v%.}."
        [[ "$t" == "SRV" ]] && v="${v%.}."
        zona_escribir "$ZONE_CONF" "$rn" "$t" "$pr" "$v" && REC_COUNT=$((REC_COUNT+1)) || true
    done < "$TSV"

    # ---- Correo: MX, SRV, SPF, DMARC, DKIM -----------------------
    if [[ -n "$EXT" ]]; then
        info "  $ZD: correo externo ($EXT): MX del proveedor, sin MX/SRV locales"
    else
        # mail y webmail siempre a ESTE servidor (si no, falla el SSL de correo)
        sed -i "/RECORD='mail' /d; /RECORD='webmail' /d" "$ZONE_CONF"
        zona_escribir "$ZONE_CONF" mail A '' "$SERVER_IP_DNS" || true
        zona_escribir "$ZONE_CONF" webmail A '' "$SERVER_IP_DNS" || true
    fi

    # SPF: uno solo. Dos registros SPF invalidan los dos.
    SPF_HESTIA=$( { grep "RECORD='@' TYPE='TXT'" "$ZONE_CONF" || true; } | grep -oP "VALUE='\K\"v=spf1[^']*" | head -1 || true)
    sed -i "/RECORD='@' TYPE='TXT' PRIORITY='[^']*' VALUE='\"v=spf1/d" "$ZONE_CONF"
    SPF_FINAL=""
    if [[ -n "$SPF_CLIENTE" ]]; then
        SPF_CLI=$(echo "$SPF_CLIENTE" | tr -d '"' | sed 's/^[[:space:]]*//')
        for ip in "${ORIGIN_IPS[@]:-}"; do [[ -n "$ip" ]] && SPF_CLI="${SPF_CLI//ip4:$ip/ip4:$SERVER_IP_DNS}"; done
        if [[ -n "$EXT" ]]; then
            SPF_FINAL="\"$SPF_CLI\""
        else
            # Correo local: el SPF de QemuCP + lo que el cliente autorizaba
            # (newsletters, CRM, Google para envios...) menos el origen.
            EXTRA=""
            ALL_Q=$(echo "$SPF_CLI" | grep -oE '[~?+-]?all\b' | tail -1 || true)
            for tok in $SPF_CLI; do
                case "$tok" in
                    v=spf1|a|+a|mx|+mx|ptr|+ptr|*all|"ip4:$SERVER_IP_DNS"|"+ip4:$SERVER_IP_DNS") ;;
                    include:*|+include:*|ip4:*|+ip4:*|ip6:*|+ip6:*|a:*|mx:*|exists:*) EXTRA="$EXTRA ${tok#+}" ;;
                esac
            done
            SPF_FINAL="\"v=spf1 a mx ip4:$SERVER_IP_DNS${EXTRA} ${ALL_Q:-~all}\""
        fi
    elif [[ -z "$EXT" ]]; then
        SPF_FINAL="${SPF_HESTIA:-\"v=spf1 a mx ip4:$SERVER_IP_DNS ~all\"}"
    fi
    # Con correo externo y sin SPF del cliente no se pone ninguno: el de
    # QemuCP (a mx ip4:este -all) haria fallar el correo de Google/Microsoft.
    [[ -n "$SPF_FINAL" ]] && zona_escribir "$ZONE_CONF" @ TXT '' "$SPF_FINAL" || true

    # DMARC: uno solo; se conserva la politica del cliente
    if [[ -n "$DMARC_CLIENTE" ]]; then
        sed -i "/RECORD='_dmarc' TYPE='TXT'/d" "$ZONE_CONF"
        zona_escribir "$ZONE_CONF" _dmarc TXT '' "$DMARC_CLIENTE" || true
    elif [[ -n "$EXT" ]]; then
        sed -i "/RECORD='_dmarc' TYPE='TXT'/d" "$ZONE_CONF"
    fi

    # DKIM de ESTE servidor (el dominio de correo se crea antes que la zona,
    # y entonces QemuCP no llega a publicarlo).
    if [[ -z "$EXT" ]] && [[ -f "$HESTIA/data/users/$CPANEL_USER/mail/$ZD.pub" ]]; then
        if ! grep -q "RECORD='mail._domainkey'" "$ZONE_CONF"; then
            P=$(grep -v ' KEY---' "$HESTIA/data/users/$CPANEL_USER/mail/$ZD.pub" | tr -d '\n')
            zona_escribir "$ZONE_CONF" mail._domainkey TXT '' "\"v=DKIM1; k=rsa; p=$P\"" || true
        fi
    fi

    # CAA que no autoriza a Let's Encrypt: el SSL fallaria
    if [[ ${#CAA_ISSUE[@]} -gt 0 ]] && ! printf '%s\n' "${CAA_ISSUE[@]}" | grep -q 'letsencrypt.org'; then
        zona_escribir "$ZONE_CONF" @ CAA '' '0 issue "letsencrypt.org"' || true
        info "  $ZD: CAA ampliado para permitir Let's Encrypt"
    fi

    # Web del dominio alojada fuera del servidor de origen: no romperla
    if [[ -n "$APEX_EXTERNA" ]]; then
        sed -i "/RECORD='@' TYPE='A' /d" "$ZONE_CONF"
        zona_escribir "$ZONE_CONF" @ A '' "$APEX_EXTERNA" || true
        pendiente "$ZD apuntaba a $APEX_EXTERNA (no es el servidor cPanel): se mantiene esa IP. Si la web se aloja aqui, cambia el A de @ a $SERVER_IP_DNS"
    fi

    # Cada web de esta zona (subdominios) debe tener su registro: si la zona
    # de cPanel no lo traia, la web no resolveria.
    for W in "${WEB_CREADOS[@]:-}"; do
        [[ -n "$W" && "$W" == *".$ZD" && -z "${ZONA_TSV[$W]:-}" ]] || continue
        WR="${W%.$ZD}"
        if ! grep -q "RECORD='$WR' " "$ZONE_CONF"; then
            zona_escribir "$ZONE_CONF" "$WR" A '' "$SERVER_IP_DNS" || true
            info "  $ZD: anadido $WR (la web $W no tenia registro DNS)"
        fi
    done

    # CNAME + otro registro con el mismo nombre: BIND rechaza la zona entera
    for N in $(grep -oP "RECORD='\K[^']+" "$ZONE_CONF" | sort -u); do
        CNT_CNAME=$(grep "RECORD='$N' " "$ZONE_CONF" | grep -c "TYPE='CNAME'" || true)
        CNT_OTRO=$(grep "RECORD='$N' " "$ZONE_CONF" | grep -vc "TYPE='CNAME'" || true)
        if [[ "${CNT_CNAME:-0}" -gt 0 && "${CNT_OTRO:-0}" -gt 0 ]]; then
            sed -i "/RECORD='$N' TYPE='CNAME'/d" "$ZONE_CONF"
            info "  $ZD: CNAME '$N' eliminado (colisionaba con otro registro)"
        elif [[ "${CNT_CNAME:-0}" -gt 1 ]]; then
            awk -v n="$N" '$0 ~ "RECORD=\047"n"\047 TYPE=\047CNAME\047" { if (seen++) next } { print }' \
                "$ZONE_CONF" > "$ZONE_CONF.qtmp" && cat "$ZONE_CONF.qtmp" > "$ZONE_CONF" && rm -f "$ZONE_CONF.qtmp"
        fi
    done

    chmod 660 "$ZONE_CONF" 2>/dev/null || true
    $BIN/v-rebuild-dns-domain "$CPANEL_USER" "$ZD" 'no' >> "$LOG" 2>&1 || pendiente "Error reconstruyendo la zona $ZD (ver $LOG)"
    log "  $ZD: $REC_COUNT registros del cliente importados"
done
if [[ ${#ZONA_TSV[@]} -gt 0 ]]; then
    $BIN/v-restart-dns >> "$LOG" 2>&1 || true
else
    info "El backup no tiene zonas DNS"
fi

# ============================================================
#  VERSION DE PHP
# ============================================================
header "Asignando version de PHP"
for DOM in "${WEB_CREADOS[@]:-}"; do
    [[ -z "$DOM" ]] && continue
    PHP_TPL="${PHP_DETECTADA[$DOM]:-}"
    if [[ -z "$PHP_TPL" ]]; then
        info "$DOM: version de PHP no detectada, se usa la de por defecto"
        continue
    fi
    if [[ -f "$HESTIA/data/templates/web/php-fpm/${PHP_TPL}.tpl" ]]; then
        $BIN/v-change-web-domain-backend-tpl "$CPANEL_USER" "$DOM" "$PHP_TPL" "no" >> "$LOG" 2>&1 \
            && log "$DOM -> $PHP_TPL" || pendiente "No se pudo asignar $PHP_TPL a $DOM"
    else
        pendiente "$DOM usaba ${PHP_TPL} en cPanel y no esta instalada aqui: se usa la de por defecto"
    fi
done

# ============================================================
#  SSL VIGENTE DE CPANEL
# ============================================================
# Si el certificado del origen sigue valido se instala: al cambiar el DNS
# la web sigue en https sin esperar a Let's Encrypt. Despues se sustituye
# por uno de Let's Encrypt con los comandos del final.
header "Importando certificados SSL vigentes"
SSL_OK=()
TLS_FILES=()
for f in "$BACKUP_PATH"/apache_tls/* "$BACKUP_PATH"/ssl/*.pem; do [[ -f "$f" ]] && TLS_FILES+=("$f"); done
if [[ ${#TLS_FILES[@]} -gt 0 ]]; then
    for DOM in "${WEB_CREADOS[@]:-}"; do
        [[ -z "$DOM" ]] && continue
        for f in "${TLS_FILES[@]}"; do
            T="$WORK_DIR/ssl-$DOM"; rm -rf "$T"; mkdir -p "$T"
            awk -v d="$T" '
                /-----BEGIN .*PRIVATE KEY-----/ { out = d "/key"; k = 1 }
                /-----BEGIN CERTIFICATE-----/ { n++; out = (n == 1) ? d "/crt" : d "/ca" }
                out { print >> out }
                /-----END/ { out = "" }' "$f"
            [[ -s "$T/key" && -s "$T/crt" ]] || continue
            openssl x509 -in "$T/crt" -noout -checkend 604800 >/dev/null 2>&1 || continue
            openssl x509 -in "$T/crt" -noout -checkhost "$DOM" 2>/dev/null | grep -q "does match" || continue
            [[ "$(openssl x509 -in "$T/crt" -noout -pubkey 2>/dev/null | sha256sum)" == \
               "$(openssl pkey -in "$T/key" -pubout 2>/dev/null | sha256sum)" ]] || continue
            mv "$T/crt" "$T/$DOM.crt"; mv "$T/key" "$T/$DOM.key"; [[ -s "$T/ca" ]] && mv "$T/ca" "$T/$DOM.ca"
            if $BIN/v-add-web-domain-ssl "$CPANEL_USER" "$DOM" "$T" '' 'no' >> "$LOG" 2>&1; then
                SSL_OK+=("$DOM")
                log "$DOM: SSL de cPanel instalado (caduca $(openssl x509 -in "$T/$DOM.crt" -noout -enddate | cut -d= -f2))"
            fi
            break
        done
    done
fi
[[ ${#SSL_OK[@]} -eq 0 ]] && info "Ningun certificado vigente que importar"

# ============================================================
#  CREDENCIALES DE LOS CMS
# ============================================================
header "Actualizando credenciales de CMS"
# Extrae el nombre de DB configurado en un fichero de config de CMS
get_config_dbname() {
    local FILE="$1"
    local TYPE="$2"
    case "$TYPE" in
        wordpress)  grep "DB_NAME" "$FILE" 2>/dev/null | grep -oP "define\(\s*['\"]DB_NAME['\"]\s*,\s*['\"]\K[^'\"]+" | head -1 ;;
        ps16)       grep "_DB_NAME_" "$FILE" 2>/dev/null | grep -oP "define\('_DB_NAME_',\s*'\K[^']+" | head -1 ;;
        ps17)       grep "database_name:" "$FILE" 2>/dev/null | awk -F: '{print $2}' | tr -d " '\"" | head -1 ;;
        joomla)     grep 'public \$db ' "$FILE" 2>/dev/null | grep -oP "=\s*'\K[^']+" | head -1 ;;
        whmcs)      grep '\$db_name' "$FILE" 2>/dev/null | grep -oP '=\s*["'"'"']\K[^"'"'"']+' | head -1 ;;
        opencart)   grep "DB_DATABASE" "$FILE" 2>/dev/null | grep -oP "'\K[^']+" | tail -1 ;;
        moodle)     grep 'CFG->dbname' "$FILE" 2>/dev/null | grep -oP "=\s*'\K[^']+" | head -1 ;;
        drupal)     grep -oP "'database'\s*=>\s*'\K[^']+" "$FILE" 2>/dev/null | head -1 ;;
        magento2)   grep -oP "'dbname'\s*=>\s*'\K[^']+" "$FILE" 2>/dev/null | head -1 ;;
        magento1)   grep -oP "<dbname><!\[CDATA\[\K[^\]]+" "$FILE" 2>/dev/null | head -1 ;;
        laravel)    grep "^DB_DATABASE=" "$FILE" 2>/dev/null | cut -d= -f2 | tr -d ' ' | head -1 ;;
        codeigniter) grep -oP "'database'\s*=>\s*'\K[^']+" "$FILE" 2>/dev/null | head -1 ;;
    esac
}

# Actualiza UN fichero de config concreto con las credenciales dadas
update_one_config() {
    local FILE="$1"
    local TYPE="$2"
    local DB="$3"
    local USER="$4"
    local PASS="$5"
    case "$TYPE" in
        wordpress)
            sed -i "s|define(\s*['\"]DB_NAME['\"].*|define('DB_NAME', '$DB');|" "$FILE" 2>/dev/null
            sed -i "s|define(\s*['\"]DB_USER['\"].*|define('DB_USER', '$USER');|" "$FILE" 2>/dev/null
            sed -i "s|define(\s*['\"]DB_PASSWORD['\"].*|define('DB_PASSWORD', '$PASS');|" "$FILE" 2>/dev/null ;;
        ps16)
            sed -i "s|define('_DB_NAME_'.*|define('_DB_NAME_', '$DB');|" "$FILE" 2>/dev/null
            sed -i "s|define('_DB_USER_'.*|define('_DB_USER_', '$USER');|" "$FILE" 2>/dev/null
            sed -i "s|define('_DB_PASSWD_'.*|define('_DB_PASSWD_', '$PASS');|" "$FILE" 2>/dev/null ;;
        ps17)
            sed -i "s|database_name:.*|database_name: $DB|" "$FILE" 2>/dev/null
            sed -i "s|database_user:.*|database_user: $USER|" "$FILE" 2>/dev/null
            sed -i "s|database_password:.*|database_password: $PASS|" "$FILE" 2>/dev/null ;;
        joomla)
            sed -i "s|public \$db =.*|public \$db = '$DB';|" "$FILE" 2>/dev/null
            sed -i "s|public \$user =.*|public \$user = '$USER';|" "$FILE" 2>/dev/null
            sed -i "s|public \$password =.*|public \$password = '$PASS';|" "$FILE" 2>/dev/null ;;
        whmcs)
            sed -i "s|\$db_name.*|\$db_name = \"$DB\";|" "$FILE" 2>/dev/null
            sed -i "s|\$db_username.*|\$db_username = \"$USER\";|" "$FILE" 2>/dev/null
            sed -i "s|\$db_password.*|\$db_password = \"$PASS\";|" "$FILE" 2>/dev/null ;;
        opencart)
            sed -i "s|define('DB_DATABASE'.*|define('DB_DATABASE', '$DB');|" "$FILE" 2>/dev/null
            sed -i "s|define('DB_USERNAME'.*|define('DB_USERNAME', '$USER');|" "$FILE" 2>/dev/null
            sed -i "s|define('DB_PASSWORD'.*|define('DB_PASSWORD', '$PASS');|" "$FILE" 2>/dev/null ;;
        moodle)
            sed -i "s|\$CFG->dbname.*|\$CFG->dbname   = '$DB';|" "$FILE" 2>/dev/null
            sed -i "s|\$CFG->dbuser.*|\$CFG->dbuser   = '$USER';|" "$FILE" 2>/dev/null
            sed -i "s|\$CFG->dbpass.*|\$CFG->dbpass   = '$PASS';|" "$FILE" 2>/dev/null ;;
        drupal|magento2|codeigniter)
            python3 -c "
import re
with open('$FILE') as f: c = f.read()
c = re.sub(r\"'(database|dbname)'(\s*)=>(\s*)'[^']*'\", r\"'\1'\2=>\3'$DB'\", c)
c = re.sub(r\"'username'(\s*)=>(\s*)'[^']*'\", r\"'username'\1=>\2'$USER'\", c)
c = re.sub(r\"'password'(\s*)=>(\s*)'[^']*'\", r\"'password'\1=>\2'$PASS'\", c)
with open('$FILE', 'w') as f: f.write(c)
" 2>/dev/null ;;
        magento1)
            sed -i "s|<dbname><!\[CDATA\[[^]]*\]\]></dbname>|<dbname><![CDATA[$DB]]></dbname>|" "$FILE" 2>/dev/null
            sed -i "s|<username><!\[CDATA\[[^]]*\]\]></username>|<username><![CDATA[$USER]]></username>|" "$FILE" 2>/dev/null
            sed -i "s|<password><!\[CDATA\[[^]]*\]\]></password>|<password><![CDATA[$PASS]]></password>|" "$FILE" 2>/dev/null ;;
        laravel)
            sed -i "s|^DB_DATABASE=.*|DB_DATABASE=$DB|" "$FILE" 2>/dev/null
            sed -i "s|^DB_USERNAME=.*|DB_USERNAME=$USER|" "$FILE" 2>/dev/null
            sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$PASS|" "$FILE" 2>/dev/null ;;
    esac
}

# Busca configs de CMS (hasta 4 niveles - soporta blog/, tienda/, etc.)
# y los empareja con su DB por el nombre que YA tienen configurado
process_domain_configs() {
    local WEBROOT="$1"
    [[ -d "$WEBROOT" ]] || return 0

    # Lista de "patron_fichero:tipo" a buscar
    local FOUND_CONFIG FOUND_TYPE CONFIG_DB MATCHED
    while IFS= read -r FOUND_CONFIG; do
        [[ -z "$FOUND_CONFIG" ]] && continue
        FOUND_TYPE=""
        case "$FOUND_CONFIG" in
            */wp-config.php) FOUND_TYPE="wordpress" ;;
            */config/settings.inc.php) FOUND_TYPE="ps16" ;;
            */app/config/parameters.php) FOUND_TYPE="ps17" ;;
            */sites/default/settings.php) FOUND_TYPE="drupal" ;;
            */app/etc/env.php) FOUND_TYPE="magento2" ;;
            */app/etc/local.xml) FOUND_TYPE="magento1" ;;
            */application/config/database.php) FOUND_TYPE="codeigniter" ;;
            */configuration.php)
                if grep -q '\$db_host' "$FOUND_CONFIG" 2>/dev/null; then
                    FOUND_TYPE="whmcs"
                elif grep -q 'public \$db' "$FOUND_CONFIG" 2>/dev/null; then
                    FOUND_TYPE="joomla"
                fi ;;
            */config.php)
                if grep -q 'CFG->dbname' "$FOUND_CONFIG" 2>/dev/null; then
                    FOUND_TYPE="moodle"
                elif grep -q "DB_DATABASE" "$FOUND_CONFIG" 2>/dev/null; then
                    FOUND_TYPE="opencart"
                fi ;;
            */.env)
                grep -q "^DB_DATABASE=" "$FOUND_CONFIG" 2>/dev/null && FOUND_TYPE="laravel" ;;
        esac
        [[ -z "$FOUND_TYPE" ]] && continue

        CONFIG_DB=$(get_config_dbname "$FOUND_CONFIG" "$FOUND_TYPE")
        [[ -z "$CONFIG_DB" ]] && continue
        info "CMS detectado ($FOUND_TYPE): $FOUND_CONFIG [DB configurada: $CONFIG_DB]"

        # Buscar la DB migrada cuyo nombre coincida con la configurada
        MATCHED=""
        for DB_ENTRY in "${DB_CREATED[@]:-}"; do
            DB_FINAL=$(echo "$DB_ENTRY" | cut -d: -f1)
            DB_USER=$(echo "$DB_ENTRY" | cut -d: -f2)
            DB_PASS=$(echo "$DB_ENTRY" | cut -d: -f3-)
            if [[ "$DB_FINAL" == "$CONFIG_DB" || "$(quitar_prefijo "${DB_FINAL#${CPANEL_USER}_}")" == "$(quitar_prefijo "$CONFIG_DB")" ]]; then
                update_one_config "$FOUND_CONFIG" "$FOUND_TYPE" "$DB_FINAL" "$DB_USER" "$DB_PASS"
                log "  Config actualizado con DB $DB_FINAL (match exacto)"
                MATCHED="yes"
                break
            fi
        done

        # Sin match exacto: si solo hay 1 DB migrada, usarla como fallback
        if [[ -z "$MATCHED" ]]; then
            if [[ ${#DB_CREATED[@]} -eq 1 ]]; then
                DB_ENTRY="${DB_CREATED[0]}"
                DB_FINAL=$(echo "$DB_ENTRY" | cut -d: -f1)
                DB_USER=$(echo "$DB_ENTRY" | cut -d: -f2)
                DB_PASS=$(echo "$DB_ENTRY" | cut -d: -f3-)
                update_one_config "$FOUND_CONFIG" "$FOUND_TYPE" "$DB_FINAL" "$DB_USER" "$DB_PASS"
                log "  Config actualizado con DB $DB_FINAL (unica DB migrada)"
            else
                pendiente "CMS en $FOUND_CONFIG usa la base de datos $CONFIG_DB y no hay ninguna migrada con ese nombre: revisar a mano"
                echo "CMS sin match: $FOUND_CONFIG (esperaba DB: $CONFIG_DB)" >> "$CREDS_FILE"
            fi
        fi
    done < <(find "$WEBROOT" -maxdepth 4 \
        \( -name "wp-config.php" -o -name "settings.inc.php" -o -name "parameters.php" \
           -o -name "configuration.php" -o -name "config.php" -o -name "settings.php" \
           -o -name "env.php" -o -name "local.xml" -o -name "database.php" -o -name ".env" \) \
        -type f 2>/dev/null)
}
if [[ ${#DB_CREATED[@]} -gt 0 ]]; then
    for DOM in "${WEB_CREADOS[@]:-}"; do
        [[ -n "$DOM" ]] && process_domain_configs "/home/$CPANEL_USER/web/$DOM/public_html"
    done
else
    info "No hay bases de datos migradas: nada que actualizar"
fi

# ============================================================
#  RECONSTRUIR Y VERIFICAR
# ============================================================
header "Reconstruyendo configuracion"
$BIN/v-rebuild-user "$CPANEL_USER" 'no' >> "$LOG" 2>&1 && log "Configuracion reconstruida" || warn "v-rebuild-user devolvio error (ver $LOG)"
$BIN/v-update-user-counters "$CPANEL_USER" >> "$LOG" 2>&1 || true
# Todo se ha creado con restart='no': hay que recargar los servicios para que
# las webs (y las versiones de PHP asignadas) se sirvan ya.
for R in v-restart-web-backend v-restart-web v-restart-proxy; do
    [[ -x "$BIN/$R" ]] && { $BIN/$R >> "$LOG" 2>&1 || pendiente "$R fallo (ver $LOG)"; }
done

# Las contrasenas originales deben seguir en passwd tras la reconstruccion
PASS_PERDIDAS=0
for MD in "$HESTIA/data/users/$CPANEL_USER/mail/"*.conf; do
    [[ -f "$MD" ]] || continue
    dom=$(basename "$MD" .conf); PW="$DEST_HOME/conf/mail/$dom/passwd"
    [[ -f "$PW" ]] || continue
    while IFS= read -r l; do
        acc=$(echo "$l" | grep -oP "^ACCOUNT='\K[^']+"); h=$(echo "$l" | grep -oP "MD5='\K[^']+")
        [[ -z "$acc" || -z "$h" ]] && continue
        if ! awk -F: -v a="$acc" -v h="$h" '$1 == a && $2 == h { f = 1 } END { exit !f }' "$PW"; then
            awk -F: -v OFS=: -v a="$acc" -v h="$h" '$1 == a { $2 = h } { print }' "$PW" > "$PW.qtmp" \
                && cat "$PW.qtmp" > "$PW" && rm -f "$PW.qtmp"
            PASS_PERDIDAS=$((PASS_PERDIDAS+1))
        fi
    done < "$MD"
done
[[ $PASS_PERDIDAS -gt 0 ]] && warn "$PASS_PERDIDAS contrasenas de correo restauradas tras la reconstruccion"

header "Verificando permisos de correo"
PERM_FIX=0
for MD in /home/$CPANEL_USER/conf/mail/*/; do
    [[ -d "$MD" ]] || continue
    if [[ "$(stat -c '%U:%G' "$MD")" != "Debian-exim:mail" ]]; then
        chown Debian-exim:mail "$MD"; chmod 771 "$MD"; PERM_FIX=$((PERM_FIX+1))
    fi
    if [[ -f "$MD/passwd" ]] && [[ "$(stat -c '%U:%G' "$MD/passwd")" != "dovecot:mail" ]]; then
        chown dovecot:mail "$MD/passwd"; chmod 660 "$MD/passwd"; PERM_FIX=$((PERM_FIX+1))
    fi
    for MF in accounts aliases ip limits antispam antivirus fwd_only dkim.pem; do
        [[ -f "$MD$MF" ]] || continue
        if [[ "$(stat -c '%U:%G' "$MD$MF")" != "Debian-exim:mail" ]]; then
            chown Debian-exim:mail "$MD$MF"; chmod 660 "$MD$MF"; PERM_FIX=$((PERM_FIX+1))
        fi
    done
done
if [[ $PERM_FIX -gt 0 ]]; then
    warn "$PERM_FIX permisos de correo corregidos"
    systemctl restart dovecot 2>/dev/null || true
    systemctl restart exim4 2>/dev/null || true
else
    log "Permisos de correo correctos"
fi

# ---- Comprobacion de las zonas DNS -------------------------------
# Se pregunta al DNS de ESTE servidor lo que respondera cuando se cambien los
# DNS del dominio: zona valida, web, correo, un solo SPF y DMARC, DKIM.
header "Comprobando las zonas DNS"
DNS_MAL=0
if command -v dig >/dev/null 2>&1 && [[ ${#ZONA_CREADA[@]} -gt 0 ]]; then
    sleep 2
    for ZD in $(printf '%s\n' "${!ZONA_CREADA[@]}" | sort); do
        PROB=()
        ZF="$DEST_HOME/conf/dns/$ZD.db"
        if command -v named-checkzone >/dev/null 2>&1 && [[ -f "$ZF" ]]; then
            named-checkzone -q "$ZD" "$ZF" >/dev/null 2>&1 || PROB+=("la zona no es valida: $(named-checkzone "$ZD" "$ZF" 2>&1 | head -1)")
        fi
        A=""
        for _i in 1 2 3 4 5; do
            A=$(dig +short +time=2 +tries=1 @127.0.0.1 "$ZD" A 2>/dev/null | head -1)
            [[ -n "$A" ]] && break; sleep 2
        done
        [[ -z "$A" ]] && PROB+=("no responde el A de $ZD")
        MX=$(dig +short +time=2 @127.0.0.1 "$ZD" MX 2>/dev/null | awk '{print $2}' | tr '\n' ' ')
        EXT="${CORREO_EXTERNO[$ZD]:-}"
        if [[ -n "$EXT" ]]; then
            [[ " $MX " == *" $EXT. "* ]] || PROB+=("MX no apunta al proveedor externo $EXT (tiene: ${MX:-nada})")
        else
            [[ " $MX " == *" mail.$ZD. "* ]] || PROB+=("MX no apunta a mail.$ZD (tiene: ${MX:-nada})")
            MA=$(dig +short +time=2 @127.0.0.1 "mail.$ZD" A 2>/dev/null | tail -1)
            [[ "$MA" == "$SERVER_IP_DNS" ]] || PROB+=("mail.$ZD no apunta a este servidor (${MA:-nada})")
            if $BIN/v-list-mail-domain "$CPANEL_USER" "$ZD" &>/dev/null; then
                dig +short +time=2 @127.0.0.1 "mail._domainkey.$ZD" TXT 2>/dev/null | grep -q "v=DKIM1" \
                    || PROB+=("falta el DKIM (mail._domainkey)")
            fi
        fi
        NSPF=$(dig +short +time=2 @127.0.0.1 "$ZD" TXT 2>/dev/null | grep -c "v=spf1" || true)
        [[ "${NSPF:-0}" -gt 1 ]] && PROB+=("$NSPF registros SPF (debe haber uno)")
        [[ -z "$EXT" && "${NSPF:-0}" -eq 0 ]] && PROB+=("sin SPF")
        NDM=$(dig +short +time=2 @127.0.0.1 "_dmarc.$ZD" TXT 2>/dev/null | grep -c "v=DMARC1" || true)
        [[ "${NDM:-0}" -gt 1 ]] && PROB+=("$NDM registros DMARC (debe haber uno)")
        if [[ ${#PROB[@]} -eq 0 ]]; then
            log "$ZD: DNS correcto (A $A, MX ${MX% }, SPF $NSPF, DMARC $NDM)"
        else
            DNS_MAL=$((DNS_MAL+1))
            for p in "${PROB[@]}"; do pendiente "DNS de $ZD: $p"; done
        fi
    done
else
    info "Sin zonas que comprobar (o sin dig)"
fi

# ============================================================
#  SSL (Let's Encrypt, cuando el DNS apunte aqui)
# ============================================================
# No se pide durante la migracion: el DNS suele apuntar aun al origen, la
# validacion falla y cada fallo cuenta para el limite de Let's Encrypt.
header "SSL de Let's Encrypt (cuando el DNS apunte aqui)"
for DOM in "${WEB_CREADOS[@]:-}"; do
    [[ -z "$DOM" ]] && continue
    MAILSSL="no"; $BIN/v-list-mail-domain "$CPANEL_USER" "$DOM" &>/dev/null && MAILSSL="yes"
    # Todos los alias del dominio (www y los aparcados): si no, el certificado
    # no los cubre y el https de los aparcados falla.
    ALI=$( { grep "^DOMAIN='$DOM'" "$HESTIA/data/users/$CPANEL_USER/web.conf" 2>/dev/null || true; } \
          | grep -oP "ALIAS='\K[^']*" || true)
    # ...pero solo los que existen en el DNS: un alias sin registro (p.ej.
    # www.blog.dominio.com) hace fallar el certificado entero.
    ALI_OK=()
    for a in ${ALI//,/ }; do
        if ! command -v dig >/dev/null 2>&1 || [[ -n "$(dig +short +time=2 +tries=1 @127.0.0.1 "$a" A 2>/dev/null)" ]]; then
            ALI_OK+=("$a")
        fi
    done
    ALI=$(IFS=,; echo "${ALI_OK[*]:-}")
    echo "  $BIN/v-add-letsencrypt-domain $CPANEL_USER $DOM '$ALI' $MAILSSL" | tee -a "$LOG"
done
[[ ${#SSL_OK[@]} -gt 0 ]] && info "Mientras tanto ya tienen el SSL de cPanel: ${SSL_OK[*]}"

# -- Limpieza ---------------------------------------------------
rm -rf "$WORK_DIR"

# -- Resumen ----------------------------------------------------
header "IMPORTACION COMPLETADA"
INFORME="/root/qemucp-import-$CPANEL_USER-$(date +%Y%m%d-%H%M).txt"
{
    echo "Importacion de $ORIG_USER (cPanel) -> $CPANEL_USER (QemuCP)  $(date)"
    echo "Plan: $PLAN"
    echo "Dominio principal: $MAIN_DOMAIN"
    echo "Dominios adicionales: ${ADDON_DOMAINS[*]:-ninguno}"
    echo "Subdominios: ${SUB_DOMAINS[*]:-ninguno}"
    echo "Alias (aparcados): ${PARKED_DOMAINS[*]:-ninguno}"
    echo "Bases de datos: ${#DB_CREATED[@]}"
    echo "Correo: $N_CUENTAS cuentas ($N_PASS_ORIG con contrasena original), $N_FWD reenvios"
    for zd in $(printf '%s\n' "${!CORREO_EXTERNO[@]}" | sort); do echo "Correo externo: $zd -> ${CORREO_EXTERNO[$zd]}"; done
    echo ""
    if [[ ${#PENDIENTES[@]} -gt 0 ]]; then
        echo "REVISAR A MANO (${#PENDIENTES[@]}):"
        for p in "${PENDIENTES[@]}"; do echo "  - $p"; done
    else
        echo "Nada pendiente de revisar."
    fi
} > "$INFORME"
cat "$INFORME" | tee -a "$LOG"
echo ""
log "Credenciales nuevas: $CREDS_FILE"
log "Informe: $INFORME"
log "Log completo: $LOG"

exit 0
