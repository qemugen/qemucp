#!/bin/bash
# ============================================================
# QemuCP - Apuntar en el cPanel los dominios migrados al servidor QemuCP
#
# Se ejecuta en el servidor cPanel (root) cuando la migracion ha terminado y
# el DNS de los dominios sigue estando en el cPanel. Usa el fichero que
# genera dns-para-cpanel.sh en el servidor QemuCP.
#
#   bash cpanel-apuntar-dns.sh dominios-qemucp.txt             solo MUESTRA
#   bash cpanel-apuntar-dns.sh dominios-qemucp.txt --aplicar   aplica
#
# Por cada dominio de la lista, en su zona del cPanel:
#   - registros A que apuntan a ESTE servidor cPanel -> IP de QemuCP
#     (los que apuntan a otros sitios -CRM, tienda, Google...- no se tocan)
#   - AAAA de este servidor -> se quitan (si no, quien entre por IPv6
#     seguiria llegando al servidor viejo)
#   - correo local en QemuCP: MX al hostname de este servidor -> mail.dominio,
#     mail.dominio -> QemuCP, SPF con la IP nueva y DKIM de QemuCP
#     (selector "mail"; sin el, el correo enviado desde QemuCP falla DKIM)
#   - correo externo (Google, Microsoft...): MX, SPF y mail.* no se tocan
#   - TTL de lo cambiado a 300 s, numero de serie +1, comprobacion con
#     named-checkzone y recarga. Si la zona no valida, se deja como estaba.
# Copia de cada zona en /root/dns-antes-de-qemucp-FECHA/.
# ============================================================
set -uo pipefail

LISTA="${1:-}"
APLICAR="no"; [[ "${2:-}" == "--aplicar" ]] && APLICAR="si"
[[ $EUID -ne 0 ]] && { echo "Ejecuta como root"; exit 1; }
[[ -f "$LISTA" ]] || { echo "Uso: bash $0 dominios-qemucp.txt [--aplicar]"; exit 1; }
ZDIR="${QEMUCP_ZONAS:-/var/named}"
[[ -d "$ZDIR" ]] || { echo "No esta $ZDIR: ¿es el servidor cPanel?"; exit 1; }

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

while IFS='|' read -r D NUEVA LOCAL DKIM; do
    [[ -z "${D:-}" || "$D" == \#* ]] && continue
    Z="$ZDIR/$D.db"
    if [[ ! -f "$Z" ]]; then echo "-- $D: no tiene zona en este cPanel, se salta"; N_SIN=$((N_SIN+1)); continue; fi
    T=$(mktemp)
    # MX al hostname de este servidor (fuera de la zona): se cambia a mail.D
    awk -v dom="$D" -v nueva="$NUEVA" -v local="$LOCAL" -v v4=" $V4 " -v v6=" $V6 " -v dkim="$DKIM" '
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
        if (esmail && (type == "A" || type == "CNAME")) tienemail = 1
        if (type == "A" && es_vieja(val)) {
            if (esmail && local != "si") { print line; next }
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
        if (local == "si" && type == "TXT" && name == dom "." && line ~ /v=spf1/) {
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
    echo "== $D (correo $([[ $LOCAL == si ]] && echo 'en QemuCP' || echo 'externo, no se toca')): $NC cambios"
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
done < "$LISTA"

echo ""
if [[ "$APLICAR" == "si" ]]; then
    echo "Zonas cambiadas: $N_OK   Sin zona aqui: $N_SIN   Con error (sin tocar): $N_MAL"
    echo "Copia de las zonas originales: $BK"
    echo "Para deshacer un dominio:  cp $BK/DOMINIO.db $ZDIR/ && rndc reload DOMINIO"
else
    echo "No se ha cambiado nada. Si todo esta bien:  bash $0 $LISTA --aplicar"
fi
