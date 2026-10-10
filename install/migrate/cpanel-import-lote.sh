#!/bin/bash
# ============================================================
# QemuCP - Importacion de cPanel EN LOTE
#
# Importa todos los backups de cPanel de una carpeta, uno detras de otro, con
# install/migrate/cpanel-import.sh, y deja un resumen con lo que hay que
# revisar de cada cuenta. Si una cuenta falla, sigue con las demas.
#
# Uso:
#   bash cpanel-import-lote.sh /carpeta/con/backups [plan]
#   bash cpanel-import-lote.sh lista.txt
#
# lista.txt: una linea por cuenta -> "ruta_backup [usuario_destino] [plan]"
#   (para renombrar cuentas que choquen o dar a cada una su plan;
#    "-" como usuario = el mismo que en cPanel)
#
# Se puede relanzar: las cuentas ya importadas se vuelven a pasar sin
# duplicar nada (el importador es reejecutable).
# ============================================================

set -uo pipefail

ORIGEN="${1:-}"
PLAN_DEF="${2:-default}"
DIR_SCRIPT="$(cd "$(dirname "$0")" && pwd)"
MIG="$DIR_SCRIPT/cpanel-import.sh"
SALIDA="/root/qemucp-lote-$(date +%Y%m%d-%H%M%S)"

[[ $EUID -ne 0 ]] && { echo "Ejecuta como root"; exit 1; }
[[ -z "$ORIGEN" ]] && { echo "Uso: bash $0 /carpeta/con/backups [plan]   o   bash $0 lista.txt"; exit 1; }
if [[ ! -f "$MIG" ]]; then
    wget -q "https://raw.githubusercontent.com/qemugen/qemucp/release/install/migrate/cpanel-import.sh" -O "$MIG" \
        || { echo "No esta cpanel-import.sh junto a este script y no se pudo descargar"; exit 1; }
fi

# Trabajos: "backup|usuario|plan"
TRABAJOS=()
if [[ -d "$ORIGEN" ]]; then
    while IFS= read -r -d '' f; do
        TRABAJOS+=("$f||$PLAN_DEF")
    done < <(find "$ORIGEN" -maxdepth 1 -type f \( -name '*.tar.gz' -o -name '*.tgz' -o -name '*.tar' \) -print0 | sort -z)
elif [[ -f "$ORIGEN" ]]; then
    while read -r b u p _; do
        [[ -z "${b:-}" || "$b" == \#* ]] && continue
        [[ "${u:-}" == "-" ]] && u=""
        TRABAJOS+=("$b|${u:-}|${p:-$PLAN_DEF}")
    done < "$ORIGEN"
else
    echo "No existe: $ORIGEN"; exit 1
fi
[[ ${#TRABAJOS[@]} -eq 0 ]] && { echo "No hay backups (.tar.gz/.tgz/.tar) en $ORIGEN"; exit 1; }

mkdir -p "$SALIDA"
RESUMEN="$SALIDA/RESUMEN.txt"
echo "Importacion en lote $(date) - ${#TRABAJOS[@]} cuentas" | tee "$RESUMEN"
echo "" | tee -a "$RESUMEN"
N_OK=0; N_MAL=0; N=0
for t in "${TRABAJOS[@]}"; do
    IFS='|' read -r b u p <<< "$t"
    N=$((N+1))
    nombre=$(basename "$b"); nombre="${nombre%.tar.gz}"; nombre="${nombre%.tgz}"; nombre="${nombre%.tar}"
    echo "[$N/${#TRABAJOS[@]}] $nombre ${u:+-> $u }(plan $p)..."
    INICIO=$(date +%s)
    bash "$MIG" "$b" "$u" "$p" < /dev/null > "$SALIDA/$nombre.log" 2>&1
    rc=$?
    cp /var/log/qemucp-cpanel-import.log "$SALIDA/$nombre.detalle.log" 2>/dev/null || true
    SEG=$(( $(date +%s) - INICIO ))
    LIMPIO=$(sed 's/\x1b\[[0-9;]*m//g' "$SALIDA/$nombre.log")
    USU=$(echo "$LIMPIO" | grep -oP 'usuario QemuCP: \K\S+' | head -1)
    INF=$(echo "$LIMPIO" | grep -oP 'Informe: \K\S+' | tail -1)
    NPEND=$(echo "$LIMPIO" | grep -oP 'REVISAR A MANO \(\K[0-9]+' | tail -1)
    if [[ $rc -eq 0 ]]; then
        N_OK=$((N_OK+1))
        printf '  OK     %-40s usuario %-14s %4ss  pendientes: %s\n' "$nombre" "${USU:-?}" "$SEG" "${NPEND:-0}" | tee -a "$RESUMEN"
        [[ -n "$INF" && -f "$INF" ]] && cp "$INF" "$SALIDA/$nombre.informe.txt"
    else
        N_MAL=$((N_MAL+1))
        MOTIVO=$(echo "$LIMPIO" | grep -E '^\[ERROR\]' | tail -1 | sed 's/^\[ERROR\] //')
        printf '  FALLO  %-40s usuario %-14s %4ss  %s\n' "$nombre" "${USU:-?}" "$SEG" "${MOTIVO:-ver $nombre.log}" | tee -a "$RESUMEN"
    fi
done

{
    echo ""
    echo "Correctas: $N_OK   Fallidas: $N_MAL"
    echo ""
    echo "Lo que hay que revisar a mano, por cuenta:"
    for f in "$SALIDA"/*.informe.txt; do
        [[ -f "$f" ]] || continue
        if grep -q "^REVISAR A MANO" "$f"; then
            echo ""; echo "== $(basename "$f" .informe.txt)"
            sed -n '/^REVISAR A MANO/,/^$/p' "$f" | tail -n +2
        fi
    done
} | tee -a "$RESUMEN"
echo ""
echo "Resumen: $RESUMEN"
echo "Logs de cada cuenta en: $SALIDA"
echo "Credenciales nuevas (paneles, bases de datos): /root/qemucp-import-credentials.txt"
[[ $N_MAL -eq 0 ]]
