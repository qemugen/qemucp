#!/bin/bash
# ============================================================
# QemuCP - Importar las respuestas automaticas de una copia de cPanel
# en una cuenta YA migrada (el importador antiguo no las traia).
#
# Uso:  bash importar-autorespuestas.sh /ruta/cpmove-USUARIO.tar.gz [usuario_qemucp]
#
# Pone cada respuesta en su buzon (v-add-mail-account-autoreply). Las que en
# cPanel tenian fecha de fin ya pasada no se activan. Se puede relanzar.
# ============================================================
set -uo pipefail
BK="${1:-}"; U="${2:-}"
BIN=/usr/local/hestia/bin
DIR="$(cd "$(dirname "$0")" && pwd)"
[[ $EUID -ne 0 ]] && { echo "Ejecuta como root"; exit 1; }
[[ -f "$BK" ]] || { echo "Uso: bash $0 /ruta/cpmove-USUARIO.tar.gz [usuario]"; exit 1; }
if [[ -z "$U" ]]; then
    U=$(basename "$BK"); U="${U%.tar.gz}"; U="${U%.tgz}"; U="${U%.tar}"
    U="${U#cpmove-}"; U="${U##*_}"
fi
$BIN/v-list-user "$U" &>/dev/null || { echo "No existe el usuario $U en QemuCP (indicalo como segundo argumento)"; exit 1; }
PY="$DIR/autorespuestas-cpanel.py"
[[ -f "$PY" ]] || wget -q -O "$PY" "https://raw.githubusercontent.com/qemugen/qemucp/release/install/migrate/autorespuestas-cpanel.py" \
    || { echo "Falta autorespuestas-cpanel.py junto a este script"; exit 1; }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
tar -xzf "$BK" -C "$T" --wildcards '*/homedir/.autorespond/*' 2>/dev/null \
    || tar -xf "$BK" -C "$T" --wildcards '*/homedir/.autorespond/*' 2>/dev/null || true
AR=$(find "$T" -type d -path '*/homedir/.autorespond' | head -1)
[[ -n "$AR" ]] || { echo "La copia no tiene respuestas automaticas (homedir/.autorespond)"; exit 0; }

N=0
while IFS=$'\t' read -r ACC DOM EST B64; do
    if [[ "$EST" == "caducada" ]]; then echo "--  $ACC@$DOM: caducada en cPanel, no se activa"; continue; fi
    if ! $BIN/v-list-mail-account "$U" "$DOM" "$ACC" &>/dev/null; then
        echo "!!  $ACC@$DOM: el buzon no existe en QemuCP (crearlo y relanzar)"; continue
    fi
    MSG=$(echo "$B64" | base64 -d)
    $BIN/v-delete-mail-account-autoreply "$U" "$DOM" "$ACC" &>/dev/null || true
    if $BIN/v-add-mail-account-autoreply "$U" "$DOM" "$ACC" "$MSG" >/dev/null 2>&1; then
        echo "OK  $ACC@$DOM: $(echo "$MSG" | head -1 | cut -c1-60)..."
        N=$((N+1))
    else
        echo "!!  $ACC@$DOM: no se pudo poner (ver el texto en el panel)"
    fi
done < <(python3 -I "$PY" "$AR")
echo ""
echo "$N respuestas automaticas activadas en $U"
