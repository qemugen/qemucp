#!/bin/bash
# ============================================================
# QemuCP - SSL de Let's Encrypt EN LOTE (tras migrar muchas cuentas)
#
# Uso:
#   bash ssl-lote.sh                 todas las cuentas
#   bash ssl-lote.sh usuario1 usuario2
#
# Pedir los certificados de 25 cuentas seguidas choca con los limites de
# Let's Encrypt si se hace a mano. Este script:
#
#  1. Solo pide el certificado de los nombres que YA apuntan a este servidor
#     en el DNS publico. Cada intento fallido cuenta para el limite de fallos
#     (5 por nombre y hora) y, si se repiten, Let's Encrypt bloquea la cuenta.
#     Un alias que aun no apunta aqui se deja fuera del certificado en lugar
#     de hacerlo fallar entero.
#  2. Usa UNA sola cuenta de Let's Encrypt para todos los usuarios. QemuCP
#     registra una cuenta por usuario y Let's Encrypt solo permite 10 altas
#     por IP cada 3 horas: con 25 usuarios, a partir del 11 fallaria todo.
#  3. Pide por separado el certificado de la web y el del correo
#     (mail.dominio), que en QemuCP son dos certificados distintos.
#  4. Se puede relanzar las veces que haga falta: lo que ya tiene Let's
#     Encrypt se salta. Lo habitual: lanzarlo tras cambiar los DNS y otra vez
#     al dia siguiente para los dominios que tardaron en propagar.
# ============================================================

set -uo pipefail

HESTIA=/usr/local/hestia
BIN=$HESTIA/bin
[[ $EUID -ne 0 ]] && { echo "Ejecuta como root"; exit 1; }
command -v dig >/dev/null || apt-get install -y -qq dnsutils >/dev/null 2>&1

LOG="/root/qemucp-ssl-lote-$(date +%Y%m%d-%H%M%S).log"
echo "SSL en lote $(date)" > "$LOG"
say() { echo -e "$1" | tee -a "$LOG"; }

# IPs de este servidor (incluida la publica si esta tras NAT)
MIS_IP=()
for ip in $($BIN/v-list-sys-ips plain 2>/dev/null | awk '{print $1}'); do
    MIS_IP+=("$ip")
    n=$( { grep -m1 "^NAT=" "$HESTIA/data/ips/$ip" 2>/dev/null || true; } | cut -d"'" -f2)
    [[ -n "$n" ]] && MIS_IP+=("$n")
done
MIS_IP6=($(ip -6 addr show scope global 2>/dev/null | awk '/inet6/ {sub(/\/.*/, "", $2); print $2}'))
es_mia() { local x; for x in "${MIS_IP[@]}" "${MIS_IP6[@]:-}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }

# Apunta aqui segun el DNS PUBLICO (no el de este servidor): IPv4 obligatoria;
# si tiene IPv6, tambien debe ser de aqui (Let's Encrypt prueba primero IPv6).
apunta_aqui() {
    local n="$1" a6 x ok=1
    a4=$(dig +short +time=3 +tries=2 @1.1.1.1 "$n" A 2>/dev/null | grep -E '^[0-9.]+$' || true)
    [[ -z "$a4" ]] && a4=$(dig +short +time=3 +tries=2 @8.8.8.8 "$n" A 2>/dev/null | grep -E '^[0-9.]+$' || true)
    [[ -z "$a4" ]] && return 1
    for x in $a4; do es_mia "$x" || ok=0; done
    a6=$(dig +short +time=3 +tries=2 @1.1.1.1 "$n" AAAA 2>/dev/null | grep ':' || true)
    for x in $a6; do es_mia "$x" || ok=0; done
    [[ $ok -eq 1 ]]
}

# Cuenta de Let's Encrypt compartida: la de admin. Se registra (una vez) en
# el momento en que hace falta, no antes.
ROOT_USER=$( { grep -m1 "^ROOT_USER=" "$HESTIA/conf/hestia.conf" || true; } | cut -d"'" -f2); ROOT_USER=${ROOT_USER:-admin}
compartir_cuenta() {
    local u="$1" ud="$HESTIA/data/users/$1/ssl" ad="$HESTIA/data/users/$ROOT_USER/ssl"
    grep -qs "^KID='https" "$ud/le.conf" && return 0
    if ! grep -qs "^KID='https" "$ad/le.conf"; then
        $BIN/v-add-letsencrypt-user "$ROOT_USER" >> "$LOG" 2>&1 || return 1
    fi
    mkdir -p "$ud"
    cp -p "$ad/user.key" "$ud/user.key" && cp -p "$ad/le.conf" "$ud/le.conf" && chmod 600 "$ud/user.key" && chmod 660 "$ud/le.conf"
}

USUARIOS=("$@")
if [[ ${#USUARIOS[@]} -eq 0 ]]; then
    USUARIOS=($($BIN/v-list-users plain 2>/dev/null | cut -f1))
fi

N_OK=0; N_MAL=0; N_ESPERA=0; N_YA=0
ESPERAN=(); FALLAN=()
for U in "${USUARIOS[@]}"; do
    WC="$HESTIA/data/users/$U/web.conf"
    [[ -f "$WC" ]] || continue
    while IFS= read -r L; do
        D=$(echo "$L" | grep -oP "^DOMAIN='\K[^']+") || continue
        [[ "$(echo "$L" | grep -oP "SUSPENDED='\K[^']*")" == "yes" ]] && continue
        WEB_YA="no"; [[ "$(echo "$L" | grep -oP "LETSENCRYPT='\K[^']*")" == "yes" ]] && WEB_YA="si"
        MAIL_DOM="no"; $BIN/v-list-mail-domain "$U" "$D" &>/dev/null && MAIL_DOM="si"
        MAIL_YA="no"
        [[ "$MAIL_DOM" == "si" ]] && [[ "$($BIN/v-list-mail-domain "$U" "$D" json 2>/dev/null | grep -oP '"LETSENCRYPT": "\K[^"]*')" == "yes" ]] && MAIL_YA="si"
        if [[ "$WEB_YA" == "si" && ( "$MAIL_DOM" == "no" || "$MAIL_YA" == "si" ) ]]; then
            N_YA=$((N_YA+1)); continue
        fi

        # ---- Web ----
        if [[ "$WEB_YA" == "no" ]]; then
            if ! apunta_aqui "$D"; then
                N_ESPERA=$((N_ESPERA+1)); ESPERAN+=("$D ($U)")
                say "  ESPERA  $D: el DNS publico aun no apunta aqui"
            else
                ALI=$(echo "$L" | grep -oP "ALIAS='\K[^']*" || true)
                OK_ALI=(); FUERA=()
                for a in ${ALI//,/ }; do
                    if apunta_aqui "$a"; then OK_ALI+=("$a"); else FUERA+=("$a"); fi
                done
                ALI_OK=$(IFS=,; echo "${OK_ALI[*]:-}")
                if compartir_cuenta "$U" && $BIN/v-add-letsencrypt-domain "$U" "$D" "$ALI_OK" >> "$LOG" 2>&1; then
                    N_OK=$((N_OK+1))
                    say "  OK      $D${ALI_OK:+ + $ALI_OK}${FUERA[*]:+   (fuera, no apuntan aqui: ${FUERA[*]})}"
                else
                    N_MAL=$((N_MAL+1)); FALLAN+=("$D ($U)")
                    say "  FALLO   $D (ver /var/log/hestia/LE-$U-$D.log)"
                fi
                sleep 2
            fi
        fi

        # ---- Correo (mail.dominio) ----
        if [[ "$MAIL_DOM" == "si" && "$MAIL_YA" == "no" ]]; then
            if apunta_aqui "mail.$D"; then
                if compartir_cuenta "$U" && $BIN/v-add-letsencrypt-domain "$U" "$D" "" yes >> "$LOG" 2>&1; then
                    N_OK=$((N_OK+1)); say "  OK      mail.$D"
                else
                    N_MAL=$((N_MAL+1)); FALLAN+=("mail.$D ($U)")
                    say "  FALLO   mail.$D (ver /var/log/hestia/LE-$U-mail.$D.log)"
                fi
                sleep 2
            else
                N_ESPERA=$((N_ESPERA+1)); ESPERAN+=("mail.$D ($U)")
                say "  ESPERA  mail.$D: el DNS publico aun no apunta aqui"
            fi
        fi
    done < "$WC"
done

say ""
say "Certificados emitidos: $N_OK   Ya tenian: $N_YA   Esperando DNS: $N_ESPERA   Fallidos: $N_MAL"
[[ $N_ESPERA -gt 0 ]] && say "Los que esperan DNS: vuelve a lanzar este script cuando apunten aqui (no cuentan como fallo)."
[[ $N_MAL -gt 0 ]] && say "Fallidos: ${FALLAN[*]}\nNo lo relances en bucle: Let's Encrypt permite 5 fallos por nombre y hora."
say "Log: $LOG"
[[ $N_MAL -eq 0 ]]
