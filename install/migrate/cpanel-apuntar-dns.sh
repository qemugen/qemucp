#!/bin/bash
# ============================================================
# QemuCP - Apuntar en el cPanel los dominios migrados al servidor QemuCP
#
# Se ejecuta en el servidor cPanel (root) cuando la migracion ha terminado y
# el DNS de los dominios sigue estando en el cPanel. Usa el fichero que
# genera dns-para-cpanel.sh en el servidor QemuCP.
#
#   bash cpanel-apuntar-dns.sh todas --bajar-ttl              1o, horas antes
#   bash cpanel-apuntar-dns.sh dominios-qemucp.txt             solo MUESTRA
#   bash cpanel-apuntar-dns.sh dominios-qemucp.txt --aplicar   aplica
#
# Con --aplicar, justo antes de cambiar el DNS de cada cuenta vuelve a copiar
# sus bases de datos al QemuCP (lo que entro en el cPanel durante la
# migracion). Sin --aplicar solo muestra que copiaria. Necesita entrar por SSH
# sin contrasena al QemuCP (ssh-copy-id root@IP_QEMUCP). --sin-bd: no copiar.
#
# Por cada dominio de la lista, en su zona del cPanel:
#   - registros A que apuntan a ESTE servidor cPanel -> IP de QemuCP
#     (los que apuntan a otros sitios -CRM, tienda, Google...- no se tocan)
#   - AAAA de este servidor -> se quitan (si no, quien entre por IPv6
#     seguiria llegando al servidor viejo)
#   - correo local en QemuCP: MX al hostname de este servidor -> mail.dominio,
#     mail.dominio -> QemuCP, SPF con la IP nueva y DKIM de QemuCP
#     (selector "mail"; sin el, el correo enviado desde QemuCP falla DKIM)
#   - SPF (cualquier dominio): ip4 del servidor viejo -> ip4 nuevo (las webs
#     envian correo -formularios- desde este servidor); no se anade nada mas
#   - correo externo (Google, Microsoft...): MX, mail.* y DKIM no se tocan
#   - TTL de lo cambiado a 300 s, numero de serie +1, comprobacion con
#     named-checkzone y recarga. Si la zona no valida, se deja como estaba.
# Copia de cada zona en /root/dns-antes-de-qemucp-FECHA/.
# ============================================================
set -uo pipefail

LISTA="${1:-}"
# Las bases de datos se vuelven a copiar SIEMPRE antes de cambiar el DNS de
# cada cuenta; --sin-bd para no hacerlo (--resincronizar-bd se acepta y no
# cambia nada: es lo de siempre).
APLICAR="no"; RESYNC="si"
for arg in "${@:2}"; do
    case "$arg" in
        --aplicar) APLICAR="si" ;;
        --sin-bd) RESYNC="no" ;;
    esac
done
[[ $EUID -ne 0 ]] && { echo "Ejecuta como root"; exit 1; }
ZDIR="${QEMUCP_ZONAS:-/var/named}"
[[ -d "$ZDIR" ]] || { echo "No esta $ZDIR: ¿es el servidor cPanel?"; exit 1; }

# ------------------------------------------------------------
# --bajar-ttl: ANTES del cambio (horas antes), baja a 300 s el TTL de todos
# los registros, sin cambiar ningun valor. Asi, cuando se aplique el cambio,
# los DNS de todo el mundo lo ven en ~5 minutos en vez de en horas (lo que
# ya tienen guardado caduca segun el TTL VIEJO; bajarlo a la vez que se
# cambia no sirve).
#   bash cpanel-apuntar-dns.sh todas --bajar-ttl
#   bash cpanel-apuntar-dns.sh dominios-qemucp.txt --bajar-ttl
# ------------------------------------------------------------
if [[ "${2:-}" == "--bajar-ttl" ]]; then
    if [[ "$LISTA" == "todas" ]]; then
        DOMS=$(cd "$ZDIR" && ls *.db 2>/dev/null | sed 's/\.db$//')
    elif [[ -f "$LISTA" ]]; then
        DOMS=$(cut -d'|' -f1 "$LISTA" | grep -v '^#')
    else
        echo "Uso: bash $0 todas|dominios-qemucp.txt --bajar-ttl"; exit 1
    fi
    BK="/root/dns-antes-de-ttl-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$BK"
    MAXTTL=0; N=0
    for D in $DOMS; do
        Z="$ZDIR/$D.db"; [[ -f "$Z" ]] || continue
        T=$(mktemp)
        awk 'BEGIN { insoa = 0 }
        {
            if (insoa) { print; if ($0 ~ /\)/) insoa = 0; next }
            if ($0 ~ /^\$TTL[ \t]+[0-9]+/) { m = $2 + 0; if (m > max) max = m; if (m > 300) $0 = "$TTL 300"; print; next }
            if ($0 ~ /^[ \t]*;/ || $0 ~ /^[ \t]*$/ || $0 ~ /^\$/) { print; next }
            if ($0 ~ /[ \t]SOA[ \t]/) { print; if ($0 ~ /\(/ && $0 !~ /\)/) insoa = 1; next }
            # TTL numerico como 2o campo (nombre TTL ...) o 1er campo si la linea empieza en blanco
            if (match($0, /^[^ \t]+[ \t]+[0-9]+[ \t]/) || match($0, /^[ \t]+[0-9]+[ \t]/)) {
                pre = $0; n = split($0, f, /[ \t]+/)
                k = ($0 ~ /^[ \t]/) ? 2 : 2
                # el TTL de los NS no cuenta para la espera (no se cambian)
                if (f[k] ~ /^[0-9]+$/) { if (f[k] + 0 > max && $0 !~ /[ \t]NS[ \t]/) max = f[k] + 0
                    if (f[k] + 0 > 300) { sub("[ \t]" f[k] "[ \t]", "\t300\t") } }
            }
            print
        }
        END { print max + 0 > "/dev/fd/3" }' "$Z" > "$T" 3> "$T.m"
        M=$(cat "$T.m"); [[ "${M:-0}" -gt "$MAXTTL" ]] && MAXTTL=$M
        if cmp -s "$T" "$Z"; then echo "-- $D: ya estaba a 300 o menos"; rm -f "$T" "$T.m"; continue; fi
        perl -0pi -e 's/(\bSOA\b[^(]*\(\s*)(\d+)/$1.($2+1)/e' "$T"
        if named-checkzone -q "$D" "$T" >/dev/null 2>&1; then
            cp -p "$Z" "$BK/"; cat "$T" > "$Z"
            rndc reload "$D" >/dev/null 2>&1 || true
            [[ -e /var/cpanel/cluster/root/config ]] && /scripts/dnscluster synczone "$D" >/dev/null 2>&1 || true
            echo "OK $D: TTL a 300 (antes hasta ${M}s)"; N=$((N+1))
        else
            echo "!! $D: no se toca (la zona resultante no valida)"
        fi
        rm -f "$T" "$T.m"
    done
    if [[ $MAXTTL -ge 3600 ]]; then ESPERA="$(( (MAXTTL + 3599) / 3600 )) hora(s)"; else ESPERA="$(( (MAXTTL + 59) / 60 )) minuto(s)"; fi
    echo ""
    echo "$N zonas con TTL 300. Copia en $BK"
    echo "Espera al menos $ESPERA (el TTL mas alto que habia en web/correo era ${MAXTTL}s) antes de aplicar el cambio:"
    echo "  bash $0 dominios-qemucp.txt --aplicar"
    exit 0
fi

[[ -f "$LISTA" ]] || { echo "Uso: bash $0 dominios-qemucp.txt [--aplicar]   |   bash $0 todas --bajar-ttl"; exit 1; }

# IPs de ESTE servidor (las que hay que sustituir): locales, la principal de
# cPanel y las publicas si esta tras NAT. QEMUCP_IPS_VIEJAS="a b" para forzar.
VIEJAS=(${QEMUCP_IPS_VIEJAS:-})
if [[ ${#VIEJAS[@]} -eq 0 ]]; then
    VIEJAS+=($(hostname -I 2>/dev/null))
    [[ -f /var/cpanel/mainip ]] && VIEJAS+=($(tr -d ' \n' < /var/cpanel/mainip))
    [[ -f /etc/ips ]] && VIEJAS+=($(cut -d: -f1 /etc/ips))
    [[ -f /var/cpanel/cpnat ]] && VIEJAS+=($(awk '{print $2}' /var/cpanel/cpnat))
fi
V4=$(printf '%s\n' "${VIEJAS[@]}" | grep -E '^[0-9]+(\.[0-9]+){3}$' | grep -v '^127\.' | sort -u | tr '\n' ' ')
V6=$(printf '%s\n' "${VIEJAS[@]}" | grep ':' | tr 'A-F' 'a-f' | sort -u | tr '\n' ' ')
echo "IPs de este servidor cPanel (se sustituyen): $V4 $V6"
[[ -z "$V4" ]] && { echo "No se detectaron las IPs de este servidor (usa QEMUCP_IPS_VIEJAS)"; exit 1; }
echo "Modo: $([[ $APLICAR == si ]] && echo 'APLICAR' || echo 'solo mostrar (anade --aplicar para aplicar)')"
echo ""

BK="/root/dns-antes-de-qemucp-$(date +%Y%m%d-%H%M%S)"
[[ "$APLICAR" == "si" ]] && mkdir -p "$BK"
N_OK=0; N_SIN=0; N_MAL=0
N_RESYNC_OK=0; N_RESYNC_MAL=0; N_RESYNC_SALTA=0

# ---- --resincronizar-bd ------------------------------------------------
# Vuelve a copiar las bases de datos de cada cuenta al QemuCP justo antes de
# cambiar su DNS: lo que entro en el cPanel mientras se exportaba e
# importaba (pedidos, usuarios, formularios...) no se pierde. Necesita
# entrar por SSH sin contrasena del cPanel al QemuCP:
#     ssh-copy-id root@IP_QEMUCP
# En el QemuCP lo recibe recibir-bd.sh, que guarda antes una copia de la BD
# y la restaura si la importacion falla.
RECEPTOR_URL="https://raw.githubusercontent.com/qemugen/qemucp/release/install/migrate/recibir-bd.sh"
declare -A SSH_LISTO=()
preparar_ssh() {  # IP -> 0 si se puede entrar y el receptor esta
    local ip="$1"
    [[ -n "${SSH_LISTO[$ip]:-}" ]] && { [[ "${SSH_LISTO[$ip]}" == si ]]; return; }
    SSH_LISTO[$ip]=no
    if ! ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "root@$ip" true 2>/dev/null; then
        echo "   !! No se puede entrar por SSH sin contrasena a root@$ip. En este cPanel:"
        echo "        ssh-keygen -t ed25519 -N \"\" -f /root/.ssh/id_ed25519   (si no hay clave)"
        echo "        ssh-copy-id root@$ip"
        return 1
    fi
    if ! ssh -n "root@$ip" "mkdir -p /root/migracion && wget -q -O /root/migracion/recibir-bd.sh '$RECEPTOR_URL?cb=$(date +%s)' && bash -n /root/migracion/recibir-bd.sh" >/dev/null 2>&1; then
        echo "   !! No se pudo dejar recibir-bd.sh en root@$ip:/root/migracion/"
        return 1
    fi
    SSH_LISTO[$ip]=si
}
bds_de() {  # usuario cPanel -> sus bases de datos
    local u="$1" p8="${1:0:8}"
    mysql -N -e "SHOW DATABASES" 2>/dev/null | grep -E "^(${u}|${p8})_" | sort -u
}
resincronizar_cuenta() {  # CU IP DOMINIO
    local cu="$1" ip="$2" dom="$3" db n=0 tam rc mal=0 out
    local dbs
    dbs=$(bds_de "$cu")
    if [[ -z "$dbs" ]]; then echo "   (sin bases de datos)"; return 0; fi
    if [[ "$APLICAR" != "si" ]]; then
        for db in $dbs; do
            tam=$(mysql -N -e "SELECT ROUND(SUM(data_length+index_length)/1048576,1) FROM information_schema.tables WHERE table_schema='$db'" 2>/dev/null)
            echo "   BD $db (${tam:-0} MB): se copiaria a $ip antes de cambiar el DNS"
        done
        preparar_ssh "$ip" && echo "   SSH a root@$ip: OK"
        return 0
    fi
    preparar_ssh "$ip" || { N_RESYNC_MAL=$((N_RESYNC_MAL+1)); return 1; }
    for db in $dbs; do
        out=$( { mysqldump --single-transaction --quick --routines --triggers --events --hex-blob \
                    --no-tablespaces --default-character-set=utf8mb4 "$db" 2>/tmp/qemucp-resync.err \
                  | gzip | ssh -o BatchMode=yes "root@$ip" "bash /root/migracion/recibir-bd.sh '$dom' '$cu' '$db'" 2>&1
                 echo "__RC ${PIPESTATUS[*]}"; } )
        read -r -a rc <<< "$(printf '%s\n' "$out" | tail -1 | sed 's/^__RC //')"
        out=$(printf '%s\n' "$out" | sed '$d')
        printf '%s\n' "$out" | sed 's/^/   /'
        if [[ ${rc[0]} -ne 0 ]]; then
            echo "   !! mysqldump fallo en $db: $(head -c 200 /tmp/qemucp-resync.err)"; mal=1
        elif [[ ${rc[2]} -eq 0 ]]; then
            N_RESYNC_OK=$((N_RESYNC_OK+1))
        elif [[ ${rc[2]} -eq 3 ]]; then
            :   # no existe en QemuCP: aviso, no bloquea
        else
            mal=1
        fi
    done
    [[ $mal -eq 0 ]] || { N_RESYNC_MAL=$((N_RESYNC_MAL+1)); return 1; }
}

procesar_linea() {  # D NUEVA LOCAL DKIM
    local D="$1" NUEVA="$2" LOCAL="$3" DKIM="$4" Z T NC
    [[ -z "${D:-}" || "$D" == \#* ]] && return
    Z="$ZDIR/$D.db"
    if [[ ! -f "$Z" ]]; then echo "-- $D: no tiene zona en este cPanel, se salta"; N_SIN=$((N_SIN+1)); return; fi
    T=$(mktemp)
    # MX al hostname de este servidor (fuera de la zona): se cambia a mail.D
    # Destinos de los NS de la zona (absolutos) y hostname de este servidor
    NSH=" $(awk -v d="$D." '$0 !~ /^[ \t]*;/ && toupper($0) ~ /[ \t]NS[ \t]/ {h=tolower($NF); if (h !~ /\.$/) h=h"."d; print h}' "$Z" | tr '\n' ' ') "
    HOSTN="$(hostname -f 2>/dev/null | tr 'A-Z' 'a-z')."
    awk -v dom="$D" -v nueva="$NUEVA" -v local="$LOCAL" -v v4=" $V4 " -v v6=" $V6 " -v dkim="$DKIM" -v nsh="$NSH" -v hostn="$HOSTN" '
    function absn(n) { if (n == "@" || n == "") return dom "."; if (n ~ /\.$/) return tolower(n); return tolower(n) "." dom "." }
    function es_vieja(ip) { return index(v4, " " ip " ") > 0 }
    function es_vieja6(ip) { return index(v6, " " tolower(ip) " ") > 0 }
    function cambio(msg) { print "   " msg > "/dev/stderr"; ncambios++ }
    BEGIN { last = dom "."; insoa = 0; tienemail = 0 }
    {
        line = $0
        if (insoa) { print line; if (line ~ /\)/) insoa = 0; next }
        if (line ~ /^[ \t]*;/ || line ~ /^[ \t]*$/ || line ~ /^\$/) { print line; next }
        n = split(line, f, /[ \t]+/)
        start = 1
        if (line ~ /^[ \t]/) { name = last; start = 2 } else { name = absn(f[1]); start = 2 }
        last = name
        # saltar TTL y clase
        i = start
        ttl = ""
        while (i <= n && (f[i] ~ /^[0-9]+[smhdwSMHDW]?$/ || toupper(f[i]) ~ /^(IN|CH|HS)$/)) { if (f[i] ~ /^[0-9]/) ttl = f[i]; i++ }
        type = toupper(f[i]); val = f[i + 1]
        if (type == "SOA") { print line; if (line ~ /\(/ && line !~ /\)/) insoa = 1; next }
        esmail = (name == "mail." dom "." || name == "webmail." dom ".")
        if (name == "mail." dom "." && (type == "A" || type == "CNAME")) tienemail = 1
        if (type == "A" && es_vieja(val)) {
            if (esmail && local != "si") { print line; next }
            # Nameservers (ns, ns1, ns2... y los nombres que la zona usa en sus
            # NS) y el hostname de este servidor NO se mueven: siguen sirviendo
            # el DNS de todos los dominios que estan en este cPanel u otros.
            if (name ~ /^ns[0-9]*\./ || index(nsh, " " name " ") > 0 || name == hostn) {
                print "   (no se toca: " name " es nameserver o el hostname de este servidor)" > "/dev/stderr"
                print line; next
            }
            cambio(name " A " val " -> " nueva)
            print name "\t300\tIN\tA\t" nueva; next
        }
        if (type == "AAAA" && es_vieja6(val)) { cambio(name " AAAA " val " -> eliminado"); next }
        if (local == "si" && type == "MX") {
            host = absn(f[i + 2])
            if (host !~ ("(^|\\.)" dom "\\.$")) {
                # el MX va a un nombre de fuera: si es el de este servidor
                cmd = "getent ahostsv4 " host " 2>/dev/null"; viejo = 0
                while ((cmd | getline r) > 0) { split(r, g, " "); if (es_vieja(g[1])) viejo = 1 }
                close(cmd)
                if (viejo) { cambio(name " MX " val " " host " -> " val " mail." dom "."); print name "\t300\tIN\tMX\t" val "\tmail." dom "."; next }
            }
        }
        if (type == "TXT" && name == dom "." && line ~ /v=spf1/) {
            nl = line; c = 0
            for (k in V) delete V[k]
            split(v4, V, " ")
            for (k in V) if (V[k] != "") c += gsub("ip4:" V[k], "ip4:" nueva, nl)
            if (c > 0) { cambio("SPF: ip4 del servidor viejo -> ip4:" nueva); print nl; next }
        }
        if (local == "si" && dkim != "" && name == "mail._domainkey." dom ".") { next }
        print line
    }
    END {
        if (local == "si" && !tienemail) { print "mail\t300\tIN\tA\t" nueva; cambio("mail." dom ". A -> " nueva " (no existia)") }
        if (local == "si" && dkim != "") {
            v = "v=DKIM1; k=rsa; p=" dkim; s = ""
            while (length(v) > 250) { s = s "\"" substr(v, 1, 250) "\" "; v = substr(v, 251) }
            s = s "\"" v "\""
            print "mail._domainkey\t300\tIN\tTXT\t" s
            cambio("DKIM de QemuCP en mail._domainkey")
        }
        print ncambios + 0 > "/dev/fd/3"
    }' "$Z" > "$T" 2> >(sed "s/^/   /" >&2) 3> "$T.n"
    sleep 0.2
    NC=$(cat "$T.n" 2>/dev/null || echo 0)
    echo "== $D (correo $([[ $LOCAL == si ]] && echo 'en QemuCP' || echo 'externo: MX y mail.* sin tocar')): $NC cambios"
    if [[ "$APLICAR" == "si" && "${NC:-0}" -gt 0 ]]; then
        cp -p "$Z" "$BK/"
        # numero de serie +1
        perl -0pi -e 's/(\bSOA\b[^(]*\(\s*)(\d+)/$1.($2+1)/e' "$T"
        if named-checkzone -q "$D" "$T" >/dev/null 2>&1; then
            cat "$T" > "$Z"
            rndc reload "$D" >/dev/null 2>&1 || /scripts/restartsrv_named >/dev/null 2>&1 || true
            [[ -f /var/cpanel/cluster/root/config ]] || [[ -d /var/cpanel/cluster/root/config ]] \
                && /scripts/dnscluster synczone "$D" >/dev/null 2>&1 || true
            echo "   aplicado (copia en $BK/$D.db)"
            N_OK=$((N_OK+1))
        else
            echo "   NO aplicado: la zona resultante no valida -> $(named-checkzone "$D" "$T" 2>&1 | head -1)"
            N_MAL=$((N_MAL+1))
        fi
    fi
    rm -f "$T" "$T.n"
}

# Lineas de la lista (se leen antes: ssh y mysqldump no deben comerse la
# entrada del bucle)
LINEAS=()
while IFS= read -r L || [[ -n "$L" ]]; do
    [[ -z "${L// }" || "$L" == \#* ]] && continue
    LINEAS+=("$L")
done < "$LISTA"

if [[ "$RESYNC" != "si" ]]; then
    for L in "${LINEAS[@]}"; do
        IFS='|' read -r D NUEVA LOCAL DKIM <<< "$L"
        procesar_linea "$D" "$NUEVA" "$LOCAL" "${DKIM:-}"
    done
else
    # Por cuenta de cPanel: primero sus bases de datos, y en cuanto estan
    # en QemuCP se cambia el DNS de sus dominios (lo mas seguido posible: lo
    # que entre en el cPanel despues de la copia se perderia).
    declare -A DOMS_DE=() IP_DE=()
    ORDEN=()
    for L in "${LINEAS[@]}"; do
        IFS='|' read -r D NUEVA _ <<< "$L"
        CU=$(awk -F': ' -v d="$D" '$1 == d {print $2; exit}' ${QEMUCP_USERDOMAINS:-/etc/userdomains} 2>/dev/null)
        [[ -z "$CU" || "$CU" == "nobody" ]] && CU="-"
        [[ -z "${DOMS_DE[$CU]+x}" ]] && { ORDEN+=("$CU"); IP_DE[$CU]="$NUEVA"; }
        DOMS_DE[$CU]+="$L"$'\n'
    done
    for CU in "${ORDEN[@]}"; do
        echo "######## Cuenta cPanel: $CU"
        RESYNC_OK=si
        if [[ "$CU" != "-" ]]; then
            resincronizar_cuenta "$CU" "${IP_DE[$CU]}" "$(printf '%s' "${DOMS_DE[$CU]}" | head -1 | cut -d'|' -f1)" || RESYNC_OK=no
        fi
        if [[ "$RESYNC_OK" == "no" && "$APLICAR" == "si" ]]; then
            echo "   !! NO se cambia el DNS de esta cuenta: sus bases de datos no se pudieron resincronizar"
            echo "      (la web sigue en el cPanel con sus datos; revisa el error y relanza)"
            while IFS= read -r L; do [[ -n "$L" ]] && N_RESYNC_SALTA=$((N_RESYNC_SALTA+1)); done <<< "${DOMS_DE[$CU]}"
            continue
        fi
        while IFS= read -r L; do
            [[ -z "$L" ]] && continue
            IFS='|' read -r D NUEVA LOCAL DKIM <<< "$L"
            procesar_linea "$D" "$NUEVA" "$LOCAL" "${DKIM:-}"
        done <<< "${DOMS_DE[$CU]}"
    done
fi

echo ""
if [[ "$APLICAR" == "si" ]]; then
    echo "Zonas cambiadas: $N_OK   Sin zona aqui: $N_SIN   Con error (sin tocar): $N_MAL"
    [[ "$RESYNC" == "si" ]] && echo "Bases de datos resincronizadas: $N_RESYNC_OK   Cuentas con error: $N_RESYNC_MAL   Dominios sin cambiar por ese error: $N_RESYNC_SALTA"
    echo "Copia de las zonas originales: $BK"
    echo "Para deshacer un dominio:  cp $BK/DOMINIO.db $ZDIR/ && rndc reload DOMINIO"
else
    echo "No se ha cambiado nada. Si todo esta bien:  bash $0 $LISTA --aplicar"
fi
