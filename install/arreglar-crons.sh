#!/bin/bash
# ============================================================================
#  QemuCP - Cola de reinicios y crons del sistema
#
#  Problema que resuelve:
#    HestiaCP NO reinicia los servicios al crear un dominio: los apunta en
#    /usr/local/hestia/data/queue/restart.pipe y los procesa un cron del
#    usuario hestiaweb:
#        */2 * * * * sudo /usr/local/hestia/bin/v-update-sys-queue restart
#    Si ese crontab falta, esta incompleto o tiene mal el propietario o los
#    permisos, cron lo ignora EN SILENCIO. Resultado: creas una web, la zona
#    queda escrita en named.conf pero BIND no la ha leido, y el dominio no
#    resuelve aunque este apuntando. Al guardar la zona desde el panel se
#    fuerza un reinicio inmediato y entonces "empieza a funcionar sin tocar
#    nada".
#
#  Uso:
#    bash arreglar-crons.sh              comprueba y corrige
#    bash arreglar-crons.sh --verificar  solo comprueba, no cambia nada
# ============================================================================

set -u
HESTIA="${HESTIA:-/usr/local/hestia}"
CRONTAB="/var/spool/cron/crontabs/hestiaweb"
SOLO_VER="no"
[ "${1:-}" = "--verificar" ] && SOLO_VER="si"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}OK${NC}     $1"; }
bad()  { echo -e "  ${RED}FALLO${NC}  $1"; }
warn() { echo -e "  ${YELLOW}AVISO${NC}  $1"; }

# Las 11 tareas que instala HestiaCP, en el mismo orden y con el mismo horario.
# Se identifican por el COMANDO, no por la linea completa, para no duplicar una
# tarea cuyo horario se haya cambiado a proposito.
TAREAS=(
    "*/2 * * * *|v-update-sys-queue restart"
    "10 00 * * *|v-update-sys-queue daily"
    "15 02 * * *|v-update-sys-queue disk"
    "10 00 * * *|v-update-sys-queue traffic"
    "30 03 * * *|v-update-sys-queue webstats"
    "*/5 * * * *|v-update-sys-queue backup"
    "10 05 * * *|v-backup-users"
    "20 00 * * *|v-update-user-stats"
    "*/5 * * * *|v-update-sys-rrd"
    "__LE__|v-update-letsencrypt-ssl"
    "41 4 * * *|v-update-sys-hestia-all"
)

echo "============================================================"
echo " QemuCP - cola de reinicios y crons"
[ "$SOLO_VER" = "si" ] && echo " MODO VERIFICACION - no se cambia nada"
echo "============================================================"
echo ""

[ -d "$HESTIA/bin" ] || { bad "No parece una instalacion de QemuCP en $HESTIA"; exit 1; }
id hestiaweb >/dev/null 2>&1 || { bad "El usuario hestiaweb no existe: instalacion incompleta"; exit 1; }

PROBLEMAS=0

# ------------------------------------------------------- 1. servicio cron
echo "--- Servicio cron ---"
SRV="cron"
systemctl list-unit-files 2>/dev/null | grep -q "^crond" && SRV="crond"
if systemctl is-active --quiet "$SRV" 2>/dev/null; then
    ok "$SRV activo"
else
    bad "$SRV NO esta activo: ninguna tarea programada se ejecuta"
    PROBLEMAS=$((PROBLEMAS+1))
    if [ "$SOLO_VER" = "no" ]; then
        systemctl enable --now "$SRV" 2>/dev/null \
            && ok "$SRV arrancado y habilitado al inicio" \
            || bad "no se pudo arrancar $SRV"
    fi
fi

# --------------------------------------- 2. permisos del directorio spool
echo ""
echo "--- Directorio de crontabs ---"
SPOOL="/var/spool/cron/crontabs"
if [ -d "$SPOOL" ]; then
    MODO=$(stat -c '%a' "$SPOOL")
    if [ "$MODO" = "1730" ]; then
        ok "$SPOOL con permisos 1730"
    else
        warn "$SPOOL tiene permisos $MODO (lo normal es 1730)"
        [ "$SOLO_VER" = "no" ] && { chmod 1730 "$SPOOL"; chown root:crontab "$SPOOL" 2>/dev/null; ok "corregido a 1730"; }
    fi
else
    bad "$SPOOL no existe"
    PROBLEMAS=$((PROBLEMAS+1))
    [ "$SOLO_VER" = "no" ] && { mkdir -p "$SPOOL"; chmod 1730 "$SPOOL"; chown root:crontab "$SPOOL" 2>/dev/null; ok "creado"; }
fi

# ------------------------------------------------ 3. crontab de hestiaweb
echo ""
echo "--- Crontab de hestiaweb ---"
if [ ! -f "$CRONTAB" ]; then
    bad "$CRONTAB NO EXISTE: esta es la causa de que los dominios nuevos no resuelvan"
    PROBLEMAS=$((PROBLEMAS+1))
    if [ "$SOLO_VER" = "no" ]; then
        printf 'MAILTO=""\nCONTENT_TYPE="text/plain; charset=utf-8"\n' > "$CRONTAB"
        ok "creado con las cabeceras"
    fi
else
    ok "existe ($(grep -c "v-" "$CRONTAB" 2>/dev/null) tareas de QemuCP)"
fi

if [ -f "$CRONTAB" ]; then
    grep -q '^MAILTO=' "$CRONTAB" || {
        warn "falta la cabecera MAILTO"
        [ "$SOLO_VER" = "no" ] && sed -i '1i MAILTO=""' "$CRONTAB"
    }

    # Minuto y hora aleatorios para la renovacion de Let's Encrypt, igual que
    # hace HestiaCP: si todos los servidores renuevan a la misma hora, se
    # concentran las peticiones contra la CA.
    LE_MIN=$(( (RANDOM % 60) ))
    LE_HOUR=$(( (RANDOM % 7) + 1 ))

    FALTAN=0
    for T in "${TAREAS[@]}"; do
        HORARIO="${T%%|*}"
        CMD="${T##*|}"
        [ "$HORARIO" = "__LE__" ] && HORARIO="$LE_MIN $LE_HOUR * * *"
        if grep -qF "$CMD" "$CRONTAB" 2>/dev/null; then
            continue
        fi
        FALTAN=$((FALTAN+1))
        if [ "$SOLO_VER" = "si" ]; then
            warn "falta: $CMD"
        else
            echo "$HORARIO sudo $HESTIA/bin/$CMD" >> "$CRONTAB"
            ok "anadida: $CMD"
        fi
    done
    if [ "$FALTAN" -eq 0 ]; then
        ok "las 11 tareas estan presentes"
    else
        PROBLEMAS=$((PROBLEMAS+1))
    fi

    # ------------------------------------------- 4. propietario y permisos
    echo ""
    echo "--- Propietario y permisos del crontab ---"
    DUENO=$(stat -c '%U:%G' "$CRONTAB")
    MODO=$(stat -c '%a' "$CRONTAB")
    # Con otro propietario o con permisos de mas, cron descarta el fichero
    # sin registrar nada en ningun log.
    if [ "$DUENO" != "hestiaweb:hestiaweb" ] && [ "$DUENO" != "hestiaweb:crontab" ]; then
        bad "propietario $DUENO (cron lo ignora en silencio)"
        PROBLEMAS=$((PROBLEMAS+1))
        [ "$SOLO_VER" = "no" ] && { chown hestiaweb:hestiaweb "$CRONTAB"; ok "corregido a hestiaweb:hestiaweb"; }
    else
        ok "propietario $DUENO"
    fi
    if [ "$MODO" != "600" ]; then
        bad "permisos $MODO (deben ser 600)"
        PROBLEMAS=$((PROBLEMAS+1))
        [ "$SOLO_VER" = "no" ] && { chmod 600 "$CRONTAB"; ok "corregido a 600"; }
    else
        ok "permisos 600"
    fi
fi

# ----------------------------------------------- 5. sudoers de hestiaweb
echo ""
echo "--- Permiso sudo de hestiaweb ---"
if sudo -u hestiaweb -n "$HESTIA/bin/v-list-sys-config" >/dev/null 2>&1 \
   || grep -rq "hestiaweb.*$HESTIA/bin" /etc/sudoers /etc/sudoers.d/ 2>/dev/null; then
    ok "hestiaweb puede ejecutar los comandos del panel con sudo"
else
    bad "hestiaweb no puede usar sudo: las tareas fallarian aunque el cron corra"
    PROBLEMAS=$((PROBLEMAS+1))
    warn "revisa /etc/sudoers.d/hestia"
fi

# -------------------------------------------------- 6. cola pendiente
echo ""
echo "--- Cola de reinicios pendiente ---"
PIPE="$HESTIA/data/queue/restart.pipe"
if [ -s "$PIPE" ]; then
    warn "hay $(wc -l < "$PIPE") reinicio(s) sin aplicar:"
    sed 's/^/        /' "$PIPE" | head -5
    if [ "$SOLO_VER" = "no" ]; then
        "$HESTIA/bin/v-update-sys-queue" restart 2>/dev/null \
            && ok "cola procesada" || warn "no se pudo procesar la cola"
    fi
else
    ok "cola vacia"
fi

if [ "$SOLO_VER" = "no" ]; then
    systemctl restart "$SRV" 2>/dev/null && ok "$SRV reiniciado para releer el crontab"
fi

# ------------------------------------------------------------- resumen
echo ""
echo "============================================================"
if [ "$PROBLEMAS" -eq 0 ]; then
    echo -e " ${GREEN}Todo correcto.${NC} La cola de reinicios funciona: al crear una web,"
    echo " BIND y Nginx recargan solos en menos de 2 minutos."
elif [ "$SOLO_VER" = "si" ]; then
    echo -e " ${RED}$PROBLEMAS problema(s).${NC} Ejecuta sin --verificar para corregirlos:"
    echo "   bash $0"
else
    echo -e " ${GREEN}$PROBLEMAS problema(s) corregido(s).${NC}"
    echo ""
    echo " Compruebalo creando un dominio de prueba: debe resolver solo,"
    echo " sin que tengas que guardar la zona:"
    echo "   v-add-domain admin pruebacron.tudominio.com"
    echo "   sleep 150"
    echo "   dig +short A pruebacron.tudominio.com @127.0.0.1"
    echo "   v-delete-domain admin pruebacron.tudominio.com"
fi
echo "============================================================"
echo ""
echo "Atajo mientras tanto, tras crear cualquier web:"
echo "  v-restart-dns yes && v-restart-web yes && v-restart-proxy yes"
exit 0
