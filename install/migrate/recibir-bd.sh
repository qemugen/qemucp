#!/bin/bash
# ============================================================
# QemuCP - Recibir una base de datos del cPanel y sustituir la migrada
#
# Lo llama cpanel-apuntar-dns.sh --resincronizar-bd desde el cPanel, por
# SSH, justo antes de apuntar el DNS: trae los datos que entraron en el
# cPanel mientras se exportaba e importaba (pedidos, formularios...).
#
#   mysqldump BD | gzip | ssh root@QEMUCP bash recibir-bd.sh DOMINIO USUARIO_CPANEL BD_CPANEL
#
# Seguridad:
#   - Comprueba que la copia llega entera ("Dump completed") antes de tocar
#     nada.
#   - Guarda la base de datos actual en /root/qemucp-resync-FECHA/ y, si la
#     importacion falla, la restaura.
#   - El usuario y la contrasena de la base de datos no cambian: la web sigue
#     funcionando igual.
#
# Codigos de salida: 0 bien, 2 copia incompleta, 3 la BD no existe en QemuCP,
# 5 fallo al importar (restaurada).
# ============================================================
set -uo pipefail
DOM="${1:-}"; CU="${2:-}"; DBO="${3:-}"
BIN=/usr/local/hestia/bin
[[ $EUID -ne 0 ]] && { echo "Ejecuta como root"; exit 1; }
[[ -n "$DOM" && -n "$CU" && -n "$DBO" ]] || { echo "Uso: ... | bash $0 DOMINIO USUARIO_CPANEL BD_CPANEL"; exit 1; }
MYSQL=$(command -v mariadb || command -v mysql)
DUMP=$(command -v mariadb-dump || command -v mysqldump)
DIR="/root/qemucp-resync-$(date +%Y%m%d)"
mkdir -p "$DIR"; chmod 700 "$DIR"

# Usuario de QemuCP del dominio y nombre de la BD (igual que el importador:
# prefijo del usuario de QemuCP + nombre sin el prefijo de cPanel)
U=$($BIN/v-search-domain-owner "$DOM" web 2>/dev/null || $BIN/v-search-domain-owner "$DOM" 2>/dev/null || true)
[[ -z "$U" ]] && { echo "!! $DBO: el dominio $DOM no esta en este QemuCP"; cat > /dev/null; exit 3; }
S="$DBO"
for p in "${CU}_" "${CU:0:8}_"; do [[ "$S" == "$p"* ]] && { S="${S#$p}"; break; }; done
S=$(echo "$S" | tr -c 'A-Za-z0-9_\n-' '_')
DB="${U}_${S}"
if ! $BIN/v-list-database "$U" "$DB" >/dev/null 2>&1; then
    cat > /dev/null
    echo "!! $DBO -> $DB: no existe en QemuCP (no estaba en la copia de la migracion). Crearla e importarla a mano."
    exit 3
fi

# 1. Recibir y comprobar que esta entera
IN="$DIR/$DB.cpanel.sql.gz"
cat > "$IN"
if ! gzip -t "$IN" 2>/dev/null || ! zcat "$IN" | tail -n 3 | grep -q "Dump completed"; then
    echo "!! $DBO -> $DB: la copia llego incompleta; no se toca nada"
    exit 2
fi

# 2. Copia de la BD actual de QemuCP
BK="$DIR/$DB.qemucp-antes.sql.gz"
if ! "$DUMP" --single-transaction --quick --routines --triggers --events --hex-blob "$DB" 2>/dev/null | gzip > "$BK"; then
    echo "!! $DB: no se pudo hacer copia de la BD actual; no se toca nada"
    exit 5
fi

# 3. Sustituir (mismos arreglos que el importador: DEFINER y DEFAULT binarios)
importar() {  # $1 = fichero .sql.gz
    "$MYSQL" -e "DROP DATABASE \`$DB\`; CREATE DATABASE \`$DB\`" || return 1
    zcat "$1" | sed -E 's/DEFINER=`[^`]+`@`[^`]+`//g; s/DEFINER=[^ *]+@[^ *]+//g;
                     s/DEFAULT x AS `([0-9A-Fa-f]+)`/DEFAULT x'"'"'\1'"'"'/g' \
        | "$MYSQL" "$DB"
}
ERR="$DIR/$DB.err"
if importar "$IN" 2> "$ERR"; then
    T=$("$MYSQL" -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DB'" 2>/dev/null)
    echo "OK $DBO -> $DB: resincronizada ($T tablas; copia anterior en $BK)"
    exit 0
fi
echo "!! $DBO -> $DB: fallo al importar ($(head -c 200 "$ERR")); se restaura la copia anterior"
importar "$BK" 2>> "$ERR" || echo "!! $DB: TAMBIEN fallo la restauracion. Copia en $BK"
exit 5
