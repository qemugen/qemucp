#!/bin/bash
# ============================================================================
#  QemuCP - Hook de post-actualizacion (RUTA CORRECTA)
#
#  EL PROBLEMA QUE CORRIGE:
#    Hasta ahora los parches de QemuCP se registraban en
#        /usr/local/hestia/data/hooks/post_update.sh
#    que HestiaCP NO EJECUTA NUNCA. El unico hook real es
#        /etc/hestiacp/hooks/post_install.sh
#    invocado al final de /var/lib/dpkg/info/hestia.postinst.
#    Consecuencia: ningun parche se reaplicaba tras un 'apt upgrade', y el
#    session.save_path duplicado reaparecia en cada actualizacion.
#
#  Reaplica, en este orden:
#    1. File Manager: $_SESSION["root"] indefinido
#    2. Plantillas php-fpm: session.save_path de fichero duplicado
#    3. Limite de subdominios (WEB_SUBDOMAINS)
#    4. Regeneracion de pools si se tocaron plantillas (el postinst ya hizo
#       upgrade_rebuild_users ANTES de llegar al hook, con las plantillas sin
#       parchear, asi que hay que rehacerlo)
#    5. Cola de reinicios (crons de hestiaweb)
#
#  Uso:
#    bash instalar-hook.sh            instala el hook
#    bash instalar-hook.sh --probar   lo ejecuta ahora para ver que hace
#    bash instalar-hook.sh --estado   solo informa, no cambia nada
# ============================================================================

set -u
HESTIA="${HESTIA:-/usr/local/hestia}"
HOOK_DIR="/etc/hestiacp/hooks"
HOOK="$HOOK_DIR/post_install.sh"
HOOK_VIEJO="$HESTIA/data/hooks/post_update.sh"
MODO="instalar"
[ "${1:-}" = "--probar" ] && MODO="probar"
[ "${1:-}" = "--estado" ] && MODO="estado"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}OK${NC}     $1"; }
bad()  { echo -e "  ${RED}FALLO${NC}  $1"; }
warn() { echo -e "  ${YELLOW}AVISO${NC}  $1"; }

echo "============================================================"
echo " QemuCP - hook de post-actualizacion"
echo "============================================================"
echo ""

[ -d "$HESTIA/bin" ] || { bad "No parece una instalacion de QemuCP en $HESTIA"; exit 1; }

# ------------------------------------------------------------------ estado
echo "--- Estado actual ---"
if [ -e "$HOOK" ]; then
    if grep -q "QemuCP" "$HOOK" 2>/dev/null; then
        ok "$HOOK instalado"
    else
        warn "$HOOK existe pero no es de QemuCP (se conservara y se anadira al final)"
    fi
else
    bad "$HOOK NO existe: los parches no se reaplican tras un apt upgrade"
fi
if [ -e "$HOOK_VIEJO" ]; then
    warn "existe el hook antiguo en una ruta que HestiaCP no ejecuta:"
    warn "  $HOOK_VIEJO"
fi
# Confirmar que el paquete realmente invoca este hook en ESTA version
POSTINST="/var/lib/dpkg/info/hestia.postinst"
if [ -f "$POSTINST" ]; then
    if grep -q "$HOOK" "$POSTINST" 2>/dev/null; then
        ok "el postinst del paquete hestia invoca $HOOK"
    else
        bad "el postinst instalado NO menciona $HOOK"
        warn "revisa: grep hooks $POSTINST"
    fi
else
    warn "no se encuentra $POSTINST (no se puede confirmar la invocacion)"
fi

if [ "$MODO" = "estado" ]; then
    echo ""
    echo "Para instalarlo:  bash $0"
    exit 0
fi

# ---------------------------------------------------------------- instalar
if [ "$MODO" = "instalar" ]; then
    echo ""
    echo "--- Instalando ---"
    mkdir -p "$HOOK_DIR" "$HESTIA/data/qemucp"

    # Si ya hay un hook de QemuCP, se reemplaza su bloque; si hay uno ajeno,
    # se conserva y el bloque de QemuCP se anade detras.
    if [ -e "$HOOK" ] && grep -q "QemuCP-BLOQUE-INICIO" "$HOOK" 2>/dev/null; then
        cp -a "$HOOK" "$HOOK.bak-$(date +%Y%m%d-%H%M%S)"
        sed -i '/# QemuCP-BLOQUE-INICIO/,/# QemuCP-BLOQUE-FIN/d' "$HOOK"
        ok "bloque anterior de QemuCP retirado (backup guardado)"
    fi
    if [ ! -e "$HOOK" ]; then
        printf '#!/bin/bash\n' > "$HOOK"
        ok "hook creado con shebang"
    elif ! head -1 "$HOOK" | grep -q '^#!'; then
        # Sin shebang el postinst lo ejecuta con /bin/sh y los bashismos fallan
        sed -i '1i #!/bin/bash' "$HOOK"
        warn "al hook le faltaba el shebang, anadido"
    fi

    cat >> "$HOOK" << 'HOOKEOF'

# QemuCP-BLOQUE-INICIO  (no editar a mano: lo regenera instalar-hook.sh)
# Lo ejecuta el postinst del paquete hestia al final de cada instalacion o
# actualizacion. El paquete sobrescribe bin/, func/, web/ y las plantillas,
# asi que aqui se reaplica todo lo propio de QemuCP.
{
    H=/usr/local/hestia
    echo "=== $(date '+%F %T') QemuCP post_install ==="

    # 0. Marca y personalizaciones de QemuCP. Va PRIMERO porque el rebrand
    #    reescribe plantillas de php-fpm y nginx, y los parches de abajo
    #    tienen que aplicarse sobre el resultado final.
    #
    #    Si el panel se instalo desde NUESTRO fork, el paquete ya trae la
    #    marca, WP-TOOL y el dashboard de rendimiento: no hay nada que
    #    injertar. Y hacerlo seria peligroso, porque el rebrand descarga de
    #    la rama release EN ESE MOMENTO, que puede ir por delante del paquete
    #    instalado, y mezclaria PHP de dos versiones (el bucle de login).
    ORIGEN=$(cut -d' ' -f1 "$H/conf/qemucp-origen" 2>/dev/null || true)
    REBRAND_URL="https://raw.githubusercontent.com/qemugen/qemucp/release/install/qemucp-rebrand.sh"
    if [ "$ORIGEN" = "fork" ]; then
        echo "  marca: el paquete ya es nuestro fork, no se injerta nada"
    elif [ -x "$H/data/qemucp/qemucp-rebrand.sh" ]; then
        bash "$H/data/qemucp/qemucp-rebrand.sh" >/dev/null 2>&1 \
            && echo "  marca QemuCP reaplicada (copia local)" \
            || echo "  AVISO: fallo el rebrand local"
    elif wget -q --timeout=30 "${REBRAND_URL}?cb=$(date +%s)" -O /tmp/qemucp-rebrand.sh 2>/dev/null; then
        bash /tmp/qemucp-rebrand.sh >/dev/null 2>&1 \
            && echo "  marca QemuCP reaplicada (descargada)" \
            || echo "  AVISO: fallo el rebrand descargado"
        rm -f /tmp/qemucp-rebrand.sh
    else
        echo "  AVISO: no se pudo reaplicar la marca (sin copia local ni red)"
    fi

    # 1. File Manager: HestiaAuth.php lee $_SESSION["root"], que el panel
    #    nunca define. Con PHP 8.x rompe la respuesta del gestor de ficheros
    #    y el usuario ve "Error desconocido" al entrar en cualquier carpeta.
    FM="$H/web/fm/backend/Services/Auth/Adapters/HestiaAuth.php"
    if [ -f "$FM" ] && grep -q '\$_SESSION\["look"\] == \$_SESSION\["root"\]' "$FM" 2>/dev/null; then
        sed -i 's|\$_SESSION\["look"\] == \$_SESSION\["root"\] &&|$_SESSION["look"] == ($_SESSION["root"] ?? "") \&\&|' "$FM"
        echo "  File Manager parcheado"
    fi

    # 2. Plantillas php-fpm: bloque de QemuCP (sesiones en Redis, OPcache,
    #    limites) UNA vez y cada directiva UNA vez. Mismo normalizador que el
    #    instalador. Cubre: plantillas regeneradas por una actualizacion que
    #    perdieron el bloque, PHP-X_Y.tpl con dos session.save_path, y bloques
    #    acumulados por relanzar el instalador antiguo.
    QEMUCP_TPL_BLOQUE=$(cat << 'QTPLEOF'
; -- QemuCP: Optimizaciones de rendimiento --
; Memoria y uploads
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 256M
php_admin_value[post_max_size] = 256M
php_admin_value[max_file_uploads] = 100
; Ejecucion
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_time] = 300
php_admin_value[max_input_vars] = 10000
; Seguridad
php_flag[display_errors] = off
php_admin_flag[log_errors] = on
; Sesiones via Redis
php_admin_value[session.save_handler] = redis
php_admin_value[session.save_path] = "tcp://127.0.0.1:6379?timeout=1&prefix=SESS_&database=1"
php_admin_value[session.gc_maxlifetime] = 1440
php_admin_value[session.cookie_httponly] = 1
php_admin_value[session.cookie_secure] = 1
; SOAP (PrestaShop)
php_value[soap.wsdl_cache_enabled] = 1
php_value[soap.wsdl_cache_ttl] = 86400
; OPcache
php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 256
php_admin_value[opcache.interned_strings_buffer] = 32
php_admin_value[opcache.max_accelerated_files] = 30000
php_admin_value[opcache.validate_timestamps] = 1
php_admin_value[opcache.revalidate_freq] = 60
php_admin_value[opcache.save_comments] = 1
QTPLEOF
)
    # Deja la plantilla con el bloque QemuCP UNA vez y cada directiva que define
    # el bloque UNA sola vez (gana el valor del bloque). Funciona por directiva,
    # no por texto: da igual como venga escrita la plantilla de origen.
    # Devuelve 0 si la cambio y 1 si ya estaba bien.
    qemucp_normalizar_tpl() {
        local f="$1" tmp
        tmp=$(mktemp)
        printf '%s\n' "$QEMUCP_TPL_BLOQUE" | awk '
            function clave(l,   k) {
                if (match(l, /^php_(admin_)?(value|flag)\[[^]]+\]/)) {
                    k = substr(l, RSTART, RLENGTH); sub(/^php_(admin_)?(value|flag)/, "", k); return k
                }
                return ""
            }
            NR == FNR { k = clave($0); if (k != "") K[k] = 1; else if ($0 ~ /^;/) C[$0] = 1; next }
            { k = clave($0); if (k != "" && (k in K)) next; if ($0 in C) next; print }
        ' - "$f" > "$tmp"
        # quitar lineas en blanco del final y poner el bloque
        sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$tmp"
        printf '\n%s\n' "$QEMUCP_TPL_BLOQUE" >> "$tmp"
        if cmp -s "$tmp" "$f"; then rm -f "$tmp"; return 1; fi
        cat "$tmp" > "$f"; rm -f "$tmp"; return 0
    }
    TOCADAS=0
    for T in "$H"/data/templates/web/php-fpm/*.tpl; do
        [ -f "$T" ] || continue
        qemucp_normalizar_tpl "$T" && TOCADAS=$((TOCADAS+1))
    done
    [ "$TOCADAS" -gt 0 ] && echo "  $TOCADAS plantilla(s) php-fpm corregidas"

    # 3. Limite de subdominios: el parche vive en bin/ y func/, que el
    #    paquete acaba de sobrescribir.
    if [ -x "$H/data/qemucp/parche-subdominios.sh" ]; then
        "$H/data/qemucp/parche-subdominios.sh" >> /var/log/qemucp-subdominios.log 2>&1 \
            && echo "  limite de subdominios reaplicado" \
            || echo "  AVISO: fallo al reaplicar el limite de subdominios"
    fi

    # 4. Si se tocaron plantillas hay que regenerar los pools: el postinst
    #    ejecuto upgrade_rebuild_users ANTES de llamar a este hook, es decir
    #    con las plantillas aun sin parchear.
    if [ "$TOCADAS" -gt 0 ]; then
        for U in $(ls "$H/data/users/" 2>/dev/null); do
            [ -f "$H/data/users/$U/web.conf" ] || continue
            "$H/bin/v-rebuild-web-domains" "$U" no >/dev/null 2>&1 || true
        done
        for V in $(ls /etc/php/ 2>/dev/null); do
            systemctl reload "php${V}-fpm" >/dev/null 2>&1 || true
        done
        echo "  pools php-fpm regenerados con las plantillas corregidas"
    fi

    # 5. Cola de reinicios: sin el cron de hestiaweb, los dominios nuevos no
    #    resuelven hasta que se guarda la zona a mano.
    if [ -x "$H/data/qemucp/arreglar-crons.sh" ]; then
        "$H/data/qemucp/arreglar-crons.sh" >> /var/log/qemucp-crons.log 2>&1 \
            && echo "  cola de reinicios verificada" \
            || echo "  AVISO: fallo al verificar la cola de reinicios"
    fi

    # 6. Retencion del paquete. 'dpkg --install' devuelve el paquete al
    #    estado 'install' y le quita el hold: tras actualizar desde el fork,
    #    el siguiente 'apt upgrade' lo cambiaria por el de upstream. Aqui no
    #    sirve apt-mark, porque dpkg tiene el bloqueo mientras se ejecuta este
    #    hook; se deja un proceso que lo reintenta hasta que dpkg termina.
    if [ "$ORIGEN" = "fork" ]; then
        nohup setsid bash -c 'for i in $(seq 1 120); do sleep 5; apt-mark hold hestia >/dev/null 2>&1 && apt-mark showhold | grep -qx hestia && break; done' >/dev/null 2>&1 &
        echo "  retencion del paquete: se reaplica en cuanto termine dpkg"
    fi

    echo "=== fin QemuCP post_install ==="
} >> /var/log/qemucp-post-install.log 2>&1
# QemuCP-BLOQUE-FIN
HOOKEOF

    chmod 755 "$HOOK"
    ok "bloque de QemuCP instalado en $HOOK"

    if ! bash -n "$HOOK" 2>/dev/null; then
        bad "el hook tiene un error de sintaxis, se restaura el backup"
        ULTIMO=$(ls -1t "$HOOK".bak-* 2>/dev/null | head -1)
        [ -n "$ULTIMO" ] && cp -a "$ULTIMO" "$HOOK"
        exit 1
    fi
    ok "sintaxis del hook correcta"

    # Los scripts a los que llama el hook tienen que estar donde los busca
    echo ""
    echo "--- Scripts que invoca el hook ---"
    # El rebrand se descarga si no esta en local, pero tener la copia evita
    # depender de la red justo despues de un apt upgrade.
    if [ ! -x "$HESTIA/data/qemucp/qemucp-rebrand.sh" ]; then
        if [ -f /root/qemucp-rebrand.sh ]; then
            cp -a /root/qemucp-rebrand.sh "$HESTIA/data/qemucp/"
            chmod +x "$HESTIA/data/qemucp/qemucp-rebrand.sh"
            ok "qemucp-rebrand.sh copiado desde /root"
        else
            warn "sin copia local de qemucp-rebrand.sh: el hook lo descargara"
        fi
    else
        ok "qemucp-rebrand.sh presente"
    fi
    for S in parche-subdominios.sh arreglar-crons.sh; do
        if [ -x "$HESTIA/data/qemucp/$S" ]; then
            ok "$S presente"
        else
            warn "falta $HESTIA/data/qemucp/$S"
            warn "  el hook lo saltara. Instalalo con:"
            warn "  bash /root/$S"
        fi
    done

    # Retirar el hook antiguo para que nadie confie en el
    if [ -e "$HOOK_VIEJO" ]; then
        mv "$HOOK_VIEJO" "$HOOK_VIEJO.NO-SE-EJECUTA-NUNCA"
        warn "hook antiguo renombrado a $(basename "$HOOK_VIEJO").NO-SE-EJECUTA-NUNCA"
    fi
fi

# ------------------------------------------------------------------ probar
if [ "$MODO" = "probar" ] || [ "$MODO" = "instalar" ]; then
    echo ""
    echo "--- Ejecutando el hook ahora (como lo haria un apt upgrade) ---"
    if [ -x "$HOOK" ]; then
        "$HOOK"
        echo "  salida registrada en /var/log/qemucp-post-install.log:"
        tail -12 /var/log/qemucp-post-install.log 2>/dev/null | sed 's/^/    /'
    else
        bad "$HOOK no es ejecutable"
    fi
fi

echo ""
echo "============================================================"
echo " Hecho. A partir de ahora, cada 'apt upgrade' del paquete"
echo " hestia reaplicara los parches solo."
echo "============================================================"
echo ""
echo "Comprobarlo de verdad, forzando una reinstalacion del paquete:"
echo "  apt-get install --reinstall -y hestia"
echo "  grep -c count_web_domains_split /usr/local/hestia/func/main.sh   # debe ser > 0"
echo "  tail -20 /var/log/qemucp-post-install.log"
exit 0
