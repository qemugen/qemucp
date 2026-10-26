#!/bin/bash
# ============================================================================
#  QemuCP - Filtro anti-bots para tiendas PrestaShop (en nginx)
#
#  Bots que recorren los filtros de la tienda (?q=Categorias-...-Precio-...)
#  generan miles de combinaciones; cada una llega a PHP y a MariaDB y tumba el
#  servidor. Un cliente real que navega ya lleva la cookie de PrestaShop
#  (PrestaShop-<32 hex>) y estos bots no la envian. Con el filtro, una
#  peticion con ?q= SIN esa cookie recibe un 403 en nginx, sin llegar a PHP.
#
#  Lo unico que cambia para una persona: si entra directamente desde un
#  buscador a una URL con filtros, sin haber pasado antes por la tienda, ve un
#  error (esas URLs no deberian estar indexadas).
#
#  Usa el mecanismo de HestiaCP para personalizar un dominio sin tocar la
#  configuracion global ni las plantillas: un fichero por dominio en
#    /home/USUARIO/conf/web/DOMINIO/nginx.conf_qemucp_filtro_ps
#    /home/USUARIO/conf/web/DOMINIO/nginx.ssl.conf_qemucp_filtro_ps
#  que se conserva al reconstruir el dominio.
#
#  Uso:
#    bash qemucp-filtro-prestashop.sh DOMINIO [DOMINIO...]   activar
#    bash qemucp-filtro-prestashop.sh --todas                 todas las PrestaShop del servidor
#    bash qemucp-filtro-prestashop.sh --quitar DOMINIO [...]  desactivar
#    bash qemucp-filtro-prestashop.sh --estado                listar donde esta activo
#    bash qemucp-filtro-prestashop.sh --probar DOMINIO        comprobar con curl
#  --silencio: solo escribe si cambia algo (para el cron).
#
#  Siempre: nginx -t antes de recargar; si no valida, se quitan los ficheros
#  nuevos y nginx sigue como estaba.
# ============================================================================
set -uo pipefail
[[ $EUID -ne 0 ]] && { echo "Ejecuta como root"; exit 1; }
HESTIA=/usr/local/hestia
BIN=$HESTIA/bin
NOMBRE="qemucp_filtro_ps"
SILENCIO=no
MODO=activar
DOMS=()
for a in "$@"; do
    case "$a" in
        --todas) MODO=todas ;;
        --quitar) MODO=quitar ;;
        --estado) MODO=estado ;;
        --probar) MODO=probar ;;
        --silencio) SILENCIO=si ;;
        -*) echo "Opcion desconocida: $a"; exit 1 ;;
        *) DOMS+=("$a") ;;
    esac
done
say() { [[ "$SILENCIO" == "si" ]] || echo "$@"; }

REGLA='# QemuCP: filtro anti-bots de PrestaShop (qemucp-filtro-prestashop.sh). No editar a mano.
# Peticion con ?q= (filtros de la tienda) sin la cookie de PrestaShop -> 403, sin llegar a PHP.
set $qemucp_ps_bot "";
if ($arg_q != "") {
    set $qemucp_ps_bot "q";
}
if ($http_cookie !~* "PrestaShop-[0-9a-f]{32}=") {
    set $qemucp_ps_bot "${qemucp_ps_bot}c";
}
if ($qemucp_ps_bot = "qc") {
    return 403;
}'

dueno() { $BIN/v-search-domain-owner "$1" web 2>/dev/null; }
conf_dir() { echo "$HESTIA_HOME/$1/conf/web/$2"; }
HESTIA_HOME=$(grep -m1 "^HOMEDIR=" $HESTIA/conf/hestia.conf 2>/dev/null | cut -d"'" -f2); HESTIA_HOME=${HESTIA_HOME:-/home}

es_prestashop() {  # $1 usuario, $2 dominio
    local w="$HESTIA_HOME/$1/web/$2/public_html"
    [[ -f "$w/app/config/parameters.php" && -d "$w/classes" ]] && return 0   # 1.7 / 8
    [[ -f "$w/config/settings.inc.php" && -d "$w/classes" ]] && grep -q "_DB_NAME_" "$w/config/settings.inc.php" 2>/dev/null && return 0   # 1.6
    return 1
}

# Recarga nginx y espera a que los procesos nuevos (con la configuracion
# nueva) esten atendiendo: "reload" vuelve al momento, pero con muchos vhosts
# y GeoIP el maestro tarda en levantar los nuevos y las primeras peticiones
# las seguian atendiendo los viejos (sin el filtro).
recargar_nginx() {
    local pidf m antes
    pidf=$(nginx -V 2>&1 | grep -oP -- '--pid-path=\K\S+'); pidf=${pidf:-/run/nginx.pid}
    m=$(cat "$pidf" 2>/dev/null)
    antes=$( [[ -n "$m" ]] && pgrep -P "$m" | sort | tr '\n' ' ')
    systemctl reload nginx 2>/dev/null || nginx -s reload
    for _ in $(seq 1 40); do
        sleep 0.25
        [[ -z "$m" ]] && break
        [[ "$(pgrep -P "$m" | sort | tr '\n' ' ')" != "$antes" ]] && { sleep 0.5; break; }
    done
}

recargar() {  # $@ = ficheros recien creados (se quitan si nginx no valida)
    if nginx -t >/tmp/qemucp-filtro-nginx.log 2>&1; then
        recargar_nginx
        return 0
    fi
    rm -f "$@"
    echo "!! nginx -t no valida con el filtro; quitado, nginx sigue como estaba:"
    tail -3 /tmp/qemucp-filtro-nginx.log
    return 1
}

activar() {  # dominios -> 0 si todo bien
    local d u c f nuevos=() n=0
    for d in "$@"; do
        u=$(dueno "$d")
        [[ -z "$u" ]] && { echo "!! $d: no es una web de este servidor"; continue; }
        c=$(conf_dir "$u" "$d")
        [[ -d "$c" ]] || { echo "!! $d: no existe $c"; continue; }
        for f in "$c/nginx.conf_$NOMBRE" "$c/nginx.ssl.conf_$NOMBRE"; do
            if [[ -f "$f" ]] && [[ "$(cat "$f")" == "$REGLA" ]]; then continue; fi
            printf '%s\n' "$REGLA" > "$f"
            chmod 644 "$f"
            nuevos+=("$f")
        done
        say "OK $d ($u): filtro activo"
        n=$((n+1))
    done
    [[ ${#nuevos[@]} -eq 0 ]] && return 0
    recargar "${nuevos[@]}" && { [[ "$SILENCIO" == "si" ]] && echo "$(date '+%F %T') filtro activado en $n dominio(s): ${nuevos[*]}"; return 0; }
    return 1
}

probar() {  # $1 dominio -> imprime resultados, 0 si se comporta bien
    local d="$1" u ip sin con normal esq="http" mal=0
    u=$(dueno "$d") || true
    ip=$(grep "DOMAIN='$d'" "$HESTIA/data/users/$u/web.conf" 2>/dev/null | grep -oP "IP='\K[^']+")
    [[ -z "$ip" ]] && ip=$(hostname -I | awk '{print $1}')
    grep "DOMAIN='$d'" "$HESTIA/data/users/$u/web.conf" 2>/dev/null | grep -q "SSL='yes'" && esq="https"
    local r=(--resolve "$d:443:$ip" --resolve "$d:80:$ip")
    sin=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "${r[@]}" "$esq://$d/?q=Precio-EUR-1-99")
    con=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "${r[@]}" -H "Cookie: PrestaShop-0123456789abcdef0123456789abcdef=qemucp" "$esq://$d/?q=Precio-EUR-1-99")
    normal=$(curl -sk -o /dev/null -w '%{http_code}' --max-time 20 "${r[@]}" "$esq://$d/")
    echo "$d  ?q= sin cookie: $sin (debe ser 403) | ?q= con cookie: $con (no 403) | sin ?q=: $normal (no 403)"
    [[ "$sin" == "403" ]] || mal=1
    [[ "$con" != "403" && "$normal" != "403" ]] || mal=1
    return $mal
}

case "$MODO" in
    activar)
        [[ ${#DOMS[@]} -eq 0 ]] && { sed -n '20,28p' "$0" | sed 's/^#  \{0,1\}//'; exit 1; }
        activar "${DOMS[@]}" || exit 1
        for d in "${DOMS[@]}"; do [[ -n "$(dueno "$d")" ]] && probar "$d"; done
        ;;
    todas)
        LISTA=()
        for wc in "$HESTIA"/data/users/*/web.conf; do
            [[ -f "$wc" ]] || continue
            u=$(basename "$(dirname "$wc")")
            for d in $(grep -oP "^DOMAIN='\K[^']+" "$wc"); do
                es_prestashop "$u" "$d" && LISTA+=("$d")
            done
        done
        [[ ${#LISTA[@]} -eq 0 ]] && { say "No hay tiendas PrestaShop en este servidor"; exit 0; }
        activar "${LISTA[@]}" || exit 1
        ;;
    quitar)
        [[ ${#DOMS[@]} -eq 0 ]] && { echo "Uso: bash $0 --quitar DOMINIO [...]"; exit 1; }
        for d in "${DOMS[@]}"; do
            u=$(dueno "$d"); [[ -z "$u" ]] && { echo "!! $d: no es una web de este servidor"; continue; }
            rm -f "$(conf_dir "$u" "$d")/nginx.conf_$NOMBRE" "$(conf_dir "$u" "$d")/nginx.ssl.conf_$NOMBRE"
            echo "OK $d: filtro quitado"
        done
        nginx -t >/dev/null 2>&1 && recargar_nginx
        ;;
    estado)
        ls "$HESTIA_HOME"/*/conf/web/*/nginx.conf_$NOMBRE 2>/dev/null | awk -F/ '{print "activo: "$(NF-1)}' | sort
        ;;
    probar)
        [[ ${#DOMS[@]} -eq 0 ]] && { echo "Uso: bash $0 --probar DOMINIO [...]"; exit 1; }
        R=0; for d in "${DOMS[@]}"; do probar "$d" || R=1; done; exit $R
        ;;
esac
