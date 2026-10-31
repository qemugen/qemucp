#!/bin/bash
# ============================================================================
#  QemuCP - Completar una instalacion base que se corto a medias
#
#  Si hst-install se para despues de crear el usuario admin y la web del
#  hostname (por ejemplo, codigo 20 porque apache/nginx no reiniciaron a
#  tiempo), faltan los crons del panel, el servicio hestia y la configuracion
#  final. Este script hace exactamente esos pasos (los mismos que el final de
#  install/hst-install-ubuntu.sh) y pone una contrasena nueva al admin.
#
#  Despues se relanza qemucp_install.sh, que aplica las optimizaciones.
#
#  Uso:  bash completar-base.sh
# ============================================================================
set -uo pipefail
[[ $EUID -ne 0 ]] && { echo "Ejecuta como root"; exit 1; }
HESTIA=/usr/local/hestia
BIN=$HESTIA/bin
export HESTIA BIN
[[ -x $BIN/v-list-users && -f $HESTIA/conf/hestia.conf ]] \
    || { echo "!! No hay panel instalado: lanza el instalador normal"; exit 1; }
CRON=/var/spool/cron/crontabs/hestiaweb
if [[ -s $CRON ]]; then
    echo "La instalacion base ya esta completa ($CRON existe). No se toca nada."
    exit 0
fi
id hestiaweb >/dev/null 2>&1 || { echo "!! No existe el usuario hestiaweb: la base se corto antes; hay que reinstalar el sistema"; exit 1; }
$BIN/v-list-user admin >/dev/null 2>&1 || { echo "!! No existe el usuario admin: la base se corto antes; hay que reinstalar el sistema"; exit 1; }

echo "[1/7] Crons del panel"
min=$((RANDOM % 60)); hour=$((RANDOM % 7 + 1))
cat > $CRON <<EOF
MAILTO=""
CONTENT_TYPE="text/plain; charset=utf-8"
*/2 * * * * sudo /usr/local/hestia/bin/v-update-sys-queue restart
10 00 * * * sudo /usr/local/hestia/bin/v-update-sys-queue daily
15 02 * * * sudo /usr/local/hestia/bin/v-update-sys-queue disk
10 00 * * * sudo /usr/local/hestia/bin/v-update-sys-queue traffic
30 03 * * * sudo /usr/local/hestia/bin/v-update-sys-queue webstats
*/5 * * * * sudo /usr/local/hestia/bin/v-update-sys-queue backup
10 05 * * * sudo /usr/local/hestia/bin/v-backup-users
20 00 * * * sudo /usr/local/hestia/bin/v-update-user-stats
*/5 * * * * sudo /usr/local/hestia/bin/v-update-sys-rrd
$min $hour * * * sudo /usr/local/hestia/bin/v-update-letsencrypt-ssl
41 4 * * * sudo /usr/local/hestia/bin/v-update-sys-hestia-all
EOF
chmod 600 $CRON
chown hestiaweb:hestiaweb $CRON

echo "[2/7] Actualizaciones automaticas, graficas, puerto 8083"
$BIN/v-add-cron-hestia-autoupdate apt >/dev/null 2>&1 || true
$BIN/v-update-sys-rrd >/dev/null 2>&1 || true
$BIN/v-change-sys-port 8083 >/dev/null 2>&1 || true
$BIN/v-update-sys-defaults >/dev/null 2>&1 || true

echo "[3/7] Servicio del panel"
update-rc.d hestia defaults >/dev/null 2>&1 || true
systemctl enable hestia >/dev/null 2>&1 || true
systemctl restart hestia || { echo "!! El servicio hestia no arranca: systemctl status hestia"; exit 1; }
chown hestiaweb:hestiaweb $HESTIA/data/sessions 2>/dev/null || true
mkdir -p /backup && chmod 755 /backup

echo "[4/7] Certificado del hostname al reiniciar"
echo "@reboot root sleep 10 && rm /etc/cron.d/hestia-ssl && PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:' && /usr/local/hestia/bin/v-add-letsencrypt-host" > /etc/cron.d/hestia-ssl

echo "[5/7] Configuracion por defecto del panel"
(
    source /etc/hestiacp/hestia.conf 2>/dev/null
    source $HESTIA/func/main.sh
    source $HESTIA/conf/hestia.conf
    source $HESTIA/func/syshealth.sh
    syshealth_repair_system_config
) >/dev/null 2>&1 || true
grep -q "hestia/bin\*" /root/.bashrc 2>/dev/null || echo 'if [ "${PATH#*/usr/local/hestia/bin*}" = "$PATH" ]; then
    . /etc/profile.d/hestia.sh
fi' >> /root/.bashrc
sort $HESTIA/conf/hestia.conf -o /tmp/qemucp-updconf && mv /tmp/qemucp-updconf $HESTIA/conf/hestia.conf
mkdir -p $HESTIA/conf/defaults && cp $HESTIA/conf/hestia.conf $HESTIA/conf/defaults/hestia.conf

echo "[6/7] Paquete hestia del fork bloqueado (no lo cambia apt upgrade)"
apt-mark hold hestia >/dev/null 2>&1 || true
[[ -f $HESTIA/conf/qemucp-origen ]] || echo "fork completar-base $(date '+%F %T')" > $HESTIA/conf/qemucp-origen

# El instalador, al relanzarlo, no toca el tema (servidor "ya instalado"):
# se pone aqui el de QemuCP, como en una instalacion nueva.
if $BIN/v-list-sys-themes plain 2>/dev/null | grep -qx qemucp; then
    $BIN/v-change-sys-config-value THEME qemucp >/dev/null 2>&1 || true
    $BIN/v-change-user-theme admin qemucp >/dev/null 2>&1 || true
fi

echo "[7/7] Contrasena nueva del admin"
PASS=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 24)
$BIN/v-change-user-password admin "$PASS" >/dev/null 2>&1 || { echo "!! No se pudo cambiar la contrasena del admin"; exit 1; }
echo "admin $PASS  ($(date '+%F %T'))" > /root/qemucp-admin.txt; chmod 600 /root/qemucp-admin.txt

sleep 2
if curl -sk -o /dev/null -w '%{http_code}' --max-time 15 https://127.0.0.1:8083/login/ | grep -q 200; then
    echo "OK: instalacion base completada. Panel respondiendo en el puerto 8083."
else
    echo "!! El panel no responde en el puerto 8083: systemctl status hestia"
fi
echo "   Usuario: admin   Contrasena: $PASS   (guardada en /root/qemucp-admin.txt)"
echo "   Ahora relanza el instalador de QemuCP para aplicar las optimizaciones."
