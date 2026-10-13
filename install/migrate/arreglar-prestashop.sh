#!/bin/bash
# ============================================================
# QemuCP - Arreglar tiendas PrestaShop migradas desde cPanel (error 500)
#
# Uso:  bash arreglar-prestashop.sh [usuario ...]     (por defecto, todos)
#
# El importador no actualizaba la base de datos en PrestaShop 1.7/8
# (app/config/parameters.php es un array PHP y se buscaba en formato YAML),
# asi que la tienda seguia con el usuario y la contrasena de cPanel -> 500.
# Ademas PrestaShop guarda en su cache rutas del servidor viejo.
#
# Por cada tienda (1.6, 1.7, 8):
#   - pone la base de datos, el usuario y la contrasena de QemuCP (los de
#     /root/qemucp-import-credentials.txt, la ultima importacion)
#   - comprueba que con esos datos se conecta
#   - vacia la cache de PrestaShop
# Copia del fichero original: <fichero>.antes-qemucp
# ============================================================
set -uo pipefail
CRED=/root/qemucp-import-credentials.txt
[[ $EUID -ne 0 ]] && { echo "Ejecuta como root"; exit 1; }
[[ -f "$CRED" ]] || { echo "No esta $CRED"; exit 1; }
MYSQL=$(command -v mariadb || command -v mysql)

USUARIOS=("$@")
[[ ${#USUARIOS[@]} -eq 0 ]] && USUARIOS=($(ls /home))

# Credenciales de QemuCP para una base de datos (ultima linea = ultima importacion)
cred() {  # $1 nombre de la DB en el config, $2 usuario QemuCP -> "db|user|pass"
    local n="$1" u="$2" l suf
    l=$(grep -F "DB: $n |" "$CRED" | tail -1)
    if [[ -z "$l" ]]; then
        # el config puede llevar el prefijo del usuario de cPanel: probar con el sufijo
        suf="${n#*_}"
        l=$(grep -F "DB: ${u}_${suf} |" "$CRED" | tail -1)
    fi
    [[ -z "$l" ]] && return 1
    echo "$l" | sed -E 's/^DB: ([^ ]+) \| User: ([^ ]+) \| Pass: (.*)$/\1|\2|\3/'
}

N_OK=0; N_MAL=0
for U in "${USUARIOS[@]}"; do
    [[ -d "/home/$U/web" ]] || continue
    while IFS= read -r F; do
        case "$F" in
            */app/config/parameters.php) TIPO=17; RAIZ="${F%/app/config/parameters.php}"
                DBN=$(grep -oP "'database_name'\s*=>\s*'\K[^']+" "$F" | head -1) ;;
            */config/settings.inc.php) TIPO=16; RAIZ="${F%/config/settings.inc.php}"
                grep -q "'_DB_NAME_'" "$F" || continue
                DBN=$(grep -oP "define\(\s*'_DB_NAME_'\s*,\s*'\K[^']+" "$F" | head -1) ;;
            *) continue ;;
        esac
        [[ -z "${DBN:-}" ]] && { echo "?? $F: no se encuentra el nombre de la base de datos"; continue; }
        C=$(cred "$DBN" "$U") || { echo "!! $RAIZ: la base de datos $DBN no esta en $CRED (no se migro con el importador)"; N_MAL=$((N_MAL+1)); continue; }
        IFS='|' read -r NDB NUS NPW <<< "$C"
        cp -p "$F" "$F.antes-qemucp" 2>/dev/null || true
        python3 - "$F" "$TIPO" "$NDB" "$NUS" "$NPW" << 'PYEOF'
import re, sys
f, tipo, db, us, pw = sys.argv[1:]
s = open(f, encoding='utf-8', errors='surrogateescape').read()
if tipo == '17':
    for k, v in (('database_name', db), ('database_user', us), ('database_password', pw)):
        s = re.sub(r"('%s'\s*=>\s*)'[^']*'" % k, lambda m: m.group(1) + "'" + v + "'", s)
else:
    for k, v in (('_DB_NAME_', db), ('_DB_USER_', us), ('_DB_PASSWD_', pw)):
        s = re.sub(r"(define\(\s*'%s'\s*,\s*)'[^']*'" % k, lambda m: m.group(1) + "'" + v + "'", s)
open(f, 'w', encoding='utf-8', errors='surrogateescape').write(s)
PYEOF
        # Cache: rutas y contenedores del servidor viejo
        if [[ $TIPO == 17 ]]; then
            rm -rf "$RAIZ/var/cache/prod" "$RAIZ/var/cache/dev" "$RAIZ/app/cache/prod" "$RAIZ/app/cache/dev" 2>/dev/null
        fi
        rm -f "$RAIZ/cache/class_index.php" 2>/dev/null
        find "$RAIZ/cache/smarty/compile" "$RAIZ/cache/smarty/cache" -mindepth 1 ! -name index.php -delete 2>/dev/null || true
        if "$MYSQL" -u "$NUS" -p"$NPW" -e "SELECT 1" "$NDB" >/dev/null 2>&1; then
            echo "OK $RAIZ (PrestaShop $([[ $TIPO == 17 ]] && echo 1.7/8 || echo 1.6)): DB $NDB, usuario $NUS, cache vaciada"
            N_OK=$((N_OK+1))
        else
            echo "!! $RAIZ: actualizado, pero no conecta con $NUS a $NDB"
            N_MAL=$((N_MAL+1))
        fi
    done < <(find "/home/$U/web" -maxdepth 6 \( -path '*/app/config/parameters.php' -o -path '*/config/settings.inc.php' \) -type f 2>/dev/null)
done
echo ""
echo "Tiendas arregladas: $N_OK   Con problemas: $N_MAL"
