#!/bin/bash
# ============================================================
# QemuCP - Limpiar los .user.ini y php.ini de cPanel en cuentas YA migradas
#
# Uso:  bash arreglar-user-ini.sh [usuario ...]      (por defecto, todos)
#
# Webs colgadas (PHP sin responder), sesiones que fallan o paginas en blanco
# tras migrar desde cPanel: el .user.ini del MultiPHP INI Editor trae
# session.save_path=/tmp, zlib.output_compression=On, max_execution_time=180...
# Deja solo memoria, tiempos, max_input_vars, subidas, zona horaria y errores,
# con tope (512M de memoria, 60 s, 256M de subida). Original en
# .user.ini.cpanel-orig; php.ini pasa a .php.ini.cpanel-orig. Se puede relanzar.
# Para deshacer en una web: mv .user.ini.cpanel-orig .user.ini
# ============================================================
set -uo pipefail
[[ $EUID -ne 0 ]] && { echo "Ejecuta como root"; exit 1; }

# ---- .user.ini / php.ini de cPanel -----------------------------
# PHP-FPM lee .user.ini de cada carpeta de la web. El de cPanel (MultiPHP INI
# Editor) trae ajustes que aqui hacen dano: session.save_path=/tmp (fuera de
# open_basedir: fallan sesiones), zlib.output_compression (doble compresion
# con nginx: paginas en blanco o colgadas), max_execution_time=180+ (un fallo
# deja la web colgada minutos), rutas del servidor viejo... Se dejan solo los
# ajustes utiles, con tope; el original queda en .user.ini.cpanel-orig.
# php.ini en la web no lo usa PHP-FPM y deja ver la configuracion: se renombra
# a .php.ini.cpanel-orig (los ficheros que empiezan por punto no se sirven).
ini_bytes() {  # 128M / 1G / 512K / 1048576 -> bytes (-1 = ilimitado)
    local v="${1^^}" n
    n="${v%[KMG]}"
    [[ "$n" =~ ^-?[0-9]+$ ]] || { echo 0; return; }
    case "$v" in
        *K) echo $((n * 1024)) ;;
        *M) echo $((n * 1048576)) ;;
        *G) echo $((n * 1073741824)) ;;
        *)  echo "$n" ;;
    esac
}
limpiar_user_ini() {  # $1 = fichero .user.ini, $2 = usuario dueno -> echo "claves_quitadas"
    local f="$1" u="$2" k v b n quitadas=0 tmp
    local -A val=()
    local orden=()
    [[ -f "$f.cpanel-orig" ]] || cp -p "$f" "$f.cpanel-orig"
    while IFS= read -r linea || [[ -n "$linea" ]]; do
        linea="${linea%$'\r'}"
        [[ "$linea" =~ ^[[:space:]]*([A-Za-z0-9_.]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
        k="${BASH_REMATCH[1],,}"; v="${BASH_REMATCH[2]}"
        if [[ "$v" =~ ^\"([^\"]*)\" || "$v" =~ ^\'([^\']*)\' ]]; then
            v="${BASH_REMATCH[1]}"
        else
            v="${v%%;*}"; v="${v%"${v##*[![:space:]]}"}"
        fi
        case "$k" in
            memory_limit)
                b=$(ini_bytes "$v")
                if [[ "$b" -lt 0 || "$b" -gt $((512 * 1048576)) ]]; then v=512M; fi
                [[ "$b" -eq 0 ]] && { quitadas=$((quitadas+1)); continue; } ;;
            upload_max_filesize|post_max_size)
                b=$(ini_bytes "$v")
                if [[ "$b" -le 0 || "$b" -gt $((256 * 1048576)) ]]; then v=256M; fi ;;
            max_execution_time|max_input_time)
                [[ "$v" =~ ^-?[0-9]+$ ]] || { quitadas=$((quitadas+1)); continue; }
                if [[ "$v" -le 0 || "$v" -gt 60 ]]; then v=60; fi ;;
            max_input_vars)
                [[ "$v" =~ ^[0-9]+$ ]] || { quitadas=$((quitadas+1)); continue; }
                [[ "$v" -gt 50000 ]] && v=50000 ;;
            max_file_uploads)
                [[ "$v" =~ ^[0-9]+$ ]] || { quitadas=$((quitadas+1)); continue; }
                [[ "$v" -gt 100 ]] && v=100 ;;
            display_errors|log_errors|error_reporting|short_open_tag|output_buffering|date.timezone|default_charset|session.gc_maxlifetime|session.cookie_lifetime)
                ;;
            *)  quitadas=$((quitadas+1)); continue ;;
        esac
        [[ -z "${val[$k]+x}" ]] && orden+=("$k")
        val[$k]="$v"
    done < "$f"
    if [[ ${#orden[@]} -eq 0 ]]; then
        rm -f "$f"
    else
        tmp=$(mktemp)
        echo "; QemuCP: ajustes de cPanel validos aqui (original en .user.ini.cpanel-orig)" > "$tmp"
        for k in "${orden[@]}"; do echo "$k = ${val[$k]}" >> "$tmp"; done
        cat "$tmp" > "$f"; rm -f "$tmp"
        chown "$u:$u" "$f" 2>/dev/null || true
    fi
    chown "$u:$u" "$f.cpanel-orig" 2>/dev/null || true
    echo "$quitadas"
}
limpiar_php_ini_web() {  # $1 = carpeta web/, $2 = usuario -> echo "n_user_ini n_php_ini"
    local base="$1" u="$2" f nu=0 np=0
    while IFS= read -r -d '' f; do
        limpiar_user_ini "$f" "$u" >/dev/null
        nu=$((nu+1))
    done < <(find "$base" -name .user.ini -type f -print0 2>/dev/null)
    while IFS= read -r -d '' f; do
        grep -q '<?' "$f" 2>/dev/null && continue   # no es un ini
        mv -f "$f" "$(dirname "$f")/.php.ini.cpanel-orig"
        np=$((np+1))
    done < <(find "$base" -name php.ini -type f -print0 2>/dev/null)
    echo "$nu $np"
}

USUARIOS=("$@")
[[ ${#USUARIOS[@]} -eq 0 ]] && USUARIOS=($(ls /home))
TU=0; TP=0
for U in "${USUARIOS[@]}"; do
    [[ -d "/home/$U/web" ]] || continue
    id "$U" &>/dev/null || continue
    read -r NU NP < <(limpiar_php_ini_web "/home/$U/web" "$U")
    [[ $((NU + NP)) -gt 0 ]] && echo "OK $U: $NU .user.ini limpiados, $NP php.ini retirados"
    TU=$((TU + NU)); TP=$((TP + NP))
done
echo ""
echo "Total: $TU .user.ini limpiados, $TP php.ini retirados"
if [[ $((TU + TP)) -gt 0 ]]; then
    for s in /lib/systemd/system/php*-fpm.service; do
        [[ -e "$s" ]] && systemctl restart "$(basename "$s")" 2>/dev/null
    done
    echo "PHP-FPM reiniciado (los cambios se aplican ya)."
fi
