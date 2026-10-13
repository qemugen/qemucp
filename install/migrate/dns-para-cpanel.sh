#!/bin/bash
# ============================================================
# QemuCP - Datos DNS para apuntar los dominios migrados desde cPanel
#
# Se ejecuta en el servidor QemuCP. Genera /root/dominios-qemucp.txt con una
# linea por dominio migrado:
#     dominio|ip_de_este_servidor|correo_local(si/no)|clave_dkim
# Ese fichero se copia al servidor cPanel y lo usa cpanel-apuntar-dns.sh para
# cambiar alli los registros (web, correo, SPF y DKIM) a este servidor.
#
# Uso:  bash dns-para-cpanel.sh [usuario1 usuario2 ...]   (por defecto, todos)
# ============================================================
set -uo pipefail
HESTIA=/usr/local/hestia
BIN=$HESTIA/bin
[[ $EUID -ne 0 ]] && { echo "Ejecuta como root"; exit 1; }

IP=$($BIN/v-list-sys-ips plain 2>/dev/null | awk '{print $1}' | head -1)
NAT=$( { grep -m1 "^NAT=" "$HESTIA/data/ips/$IP" 2>/dev/null || true; } | cut -d"'" -f2)
IP_PUB="${QEMUCP_IP:-${NAT:-$IP}}"
[[ "$IP_PUB" =~ ^[0-9.]+$ ]] || { echo "No se pudo detectar la IP publica (usa QEMUCP_IP=x.x.x.x)"; exit 1; }

USUARIOS=("$@")
[[ ${#USUARIOS[@]} -eq 0 ]] && USUARIOS=($($BIN/v-list-users plain 2>/dev/null | cut -f1))

OUT=/root/dominios-qemucp.txt
: > "$OUT"
N=0
for U in "${USUARIOS[@]}"; do
    DC="$HESTIA/data/users/$U/dns.conf"
    [[ -f "$DC" ]] || continue
    for D in $(grep -oP "^DOMAIN='\K[^']+" "$DC"); do
        LOCAL="no"; DKIM=""
        if $BIN/v-list-mail-domain "$U" "$D" &>/dev/null; then
            LOCAL="si"
            P="$HESTIA/data/users/$U/mail/$D.pub"
            [[ -f "$P" ]] && DKIM=$(grep -v ' KEY---' "$P" | tr -d '\n')
        fi
        echo "$D|$IP_PUB|$LOCAL|$DKIM" >> "$OUT"
        N=$((N+1))
    done
done
echo "$N dominios en $OUT (IP $IP_PUB)"
echo ""
echo "Siguiente paso - copialo al servidor cPanel y alli:"
echo "  bash cpanel-apuntar-dns.sh dominios-qemucp.txt            (muestra los cambios, no toca nada)"
echo "  bash cpanel-apuntar-dns.sh dominios-qemucp.txt --aplicar  (los aplica)"
