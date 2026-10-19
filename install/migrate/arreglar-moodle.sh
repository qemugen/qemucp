#!/bin/bash
# ============================================================
# QemuCP - Arreglar Moodle migrados desde cPanel
#   "Fatal error: $CFG->dataroot is not configured properly, directory does
#    not exist or is not accessible!"
#
# Uso:  bash arreglar-moodle.sh [usuario ...]      (por defecto, todos)
#
# En cPanel la carpeta de datos de Moodle suele estar en /home/USUARIO/moodledata,
# fuera de la web. En QemuCP PHP solo puede leer y escribir dentro de la web
# del dominio (open_basedir): public_html y private. Este script:
#   - mueve moodledata a /home/USUARIO/web/DOMINIO/private/moodledata
#     (fuera de public_html: no accesible desde el navegador)
#   - cambia $CFG->dataroot en config.php (copia en config.php.antes-qemucp)
#   - vacia las caches de Moodle (llevan rutas del servidor viejo)
# Se puede relanzar.
# ============================================================
set -uo pipefail
[[ $EUID -ne 0 ]] && { echo "Ejecuta como root"; exit 1; }

moodle_dataroot() {  # $1 = config.php de un Moodle en /home/U/web/DOM/public_html/...
    local cfg="$1" u dom old new src c
    u=$(echo "$cfg" | cut -d/ -f3); dom=$(echo "$cfg" | cut -d/ -f5)
    old=$(grep -oP "\\\$CFG->dataroot\s*=\s*['\"]\K[^'\"]+" "$cfg" | head -1)
    [[ -z "$old" ]] && { echo "?? $cfg: sin \$CFG->dataroot"; return 1; }
    new="/home/$u/web/$dom/private/moodledata"
    if [[ "$old" == "$new" ]]; then echo "OK $dom: ya estaba bien ($new)"; return 0; fi
    # Ya accesible (dentro de la web del dominio) y existe: no se toca
    if [[ "$old" == /home/$u/web/$dom/* && -d "$old" ]]; then echo "OK $dom: dataroot accesible ($old)"; return 0; fi
    src=""
    for c in "$old" "/home/$u/${old#/home*/*/}"; do
        [[ -d "$c" ]] && { src="$c"; break; }
    done
    mkdir -p "/home/$u/web/$dom/private"
    if [[ -n "$src" ]]; then
        if [[ -e "$new" ]]; then rsync -a "$src/" "$new/" && rm -rf "$src"; else mv "$src" "$new"; fi
    else
        mkdir -p "$new"
        echo "!! $dom: no se encontro la carpeta de datos ($old): se crea vacia. Faltaran los ficheros subidos a Moodle"
    fi
    rm -rf "$new/cache" "$new/localcache" "$new/sessions" "$new/temp" 2>/dev/null
    chown -R "$u:$u" "$new"; chmod 770 "$new"
    cp -p "$cfg" "$cfg.antes-qemucp"
    sed -i -E "s#(\\\$CFG->dataroot[[:space:]]*=[[:space:]]*)['\"][^'\"]*['\"]#\1'$new'#" "$cfg"
    echo "OK $dom: dataroot $old -> $new${src:+ (datos movidos desde $src)}"
}

USUARIOS=("$@")
[[ ${#USUARIOS[@]} -eq 0 ]] && USUARIOS=($(ls /home))
N=0
for U in "${USUARIOS[@]}"; do
    [[ -d "/home/$U/web" ]] || continue
    while IFS= read -r CFG; do
        grep -qP '\$CFG->dataroot\s*=' "$CFG" 2>/dev/null || continue
        moodle_dataroot "$CFG" && N=$((N+1))
    done < <(find "/home/$U/web" -maxdepth 5 -path '*/public_html*' -name config.php -type f 2>/dev/null)
done
echo ""
echo "Moodle revisados: $N"
echo "Si la web va por https, revisa tambien \$CFG->wwwroot en su config.php (http:// -> https://)."
