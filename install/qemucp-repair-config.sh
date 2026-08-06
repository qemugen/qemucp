#!/bin/bash
# ============================================================
# QemuCP - Reparar hestia.conf tras reinstall o instalacion parcial
# Uso: bash qemucp-repair-config.sh
#
# Repara valores criticos que un 'apt reinstall hestia' o una
# instalacion interrumpida pueden dejar sin escribir, causando:
#   - Pestanas del panel que faltan (BBDD, DNS, RESPALDOS, Firewall)
#   - "WEB_SYSTEM is not enabled" al crear dominios
#   - listen sin puerto -> nginx no arranca -> dominio no se crea
# ============================================================
HESTIA="/usr/local/hestia"
HCONF="$HESTIA/conf/hestia.conf"

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[OK]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

[ -f "$HCONF" ] || { echo "No existe $HCONF - QemuCP no instalado"; exit 1; }

REPAIRED=0
ensure_conf() {
    local key="$1" val="$2"
    if ! grep -q "^${key}=" "$HCONF" 2>/dev/null; then
        echo "${key}='${val}'" >> "$HCONF"
        log "Reparado: ${key}='${val}'"
        REPAIRED=$((REPAIRED+1))
    fi
}

echo "Verificando hestia.conf..."

# --- WEB basicos ---
if systemctl is-active --quiet apache2 2>/dev/null; then
    ensure_conf "WEB_SYSTEM" "apache2"
elif systemctl is-active --quiet nginx 2>/dev/null; then
    ensure_conf "WEB_SYSTEM" "nginx"
fi
ensure_conf "WEB_BACKEND" "php-fpm"
ensure_conf "WEB_SSL" "mod_ssl"
systemctl is-active --quiet nginx 2>/dev/null && ensure_conf "PROXY_SYSTEM" "nginx"

# --- PUERTOS ---
ensure_conf "WEB_PORT" "8080"
ensure_conf "WEB_SSL_PORT" "8443"
ensure_conf "PROXY_PORT" "80"
ensure_conf "PROXY_SSL_PORT" "443"

# --- Bases de datos ---
if systemctl is-active --quiet mariadb 2>/dev/null || systemctl is-active --quiet mysql 2>/dev/null; then
    ensure_conf "DB_SYSTEM" "mysql"
    $HESTIA/bin/v-add-database-host mysql localhost root '' 2>/dev/null || true
fi

# --- DNS ---
(systemctl is-active --quiet named 2>/dev/null || systemctl is-active --quiet bind9 2>/dev/null) && ensure_conf "DNS_SYSTEM" "bind9"

# --- Correo ---
systemctl is-active --quiet exim4 2>/dev/null && ensure_conf "MAIL_SYSTEM" "exim4"
systemctl is-active --quiet dovecot 2>/dev/null && ensure_conf "IMAP_SYSTEM" "dovecot"
systemctl is-active --quiet dovecot 2>/dev/null && ensure_conf "SIEVE_SYSTEM" "yes"
(systemctl is-active --quiet spamassassin 2>/dev/null || systemctl is-active --quiet spamd 2>/dev/null) && ensure_conf "ANTISPAM_SYSTEM" "spamassassin"
systemctl is-active --quiet clamav-daemon 2>/dev/null && ensure_conf "ANTIVIRUS_SYSTEM" "clamav"

# --- Firewall ---
if command -v iptables >/dev/null 2>&1; then
    ensure_conf "FIREWALL_SYSTEM" "iptables"
    systemctl is-active --quiet fail2ban 2>/dev/null && ensure_conf "FIREWALL_EXTENSION" "fail2ban"
fi

# --- FTP ---
systemctl is-active --quiet vsftpd 2>/dev/null && ensure_conf "FTP_SYSTEM" "vsftpd"
systemctl is-active --quiet proftpd 2>/dev/null && ensure_conf "FTP_SYSTEM" "proftpd"

# --- Otros ---
ensure_conf "STATS_SYSTEM" "awstats"
ensure_conf "WEBMAIL_SYSTEM" "roundcube"
ensure_conf "BACKUP_SYSTEM" "local"
ensure_conf "CRON_SYSTEM" "cron"

# --- Reiniciar si hubo cambios ---
echo ""
if [ $REPAIRED -gt 0 ]; then
    systemctl restart hestia 2>/dev/null || true
    log "$REPAIRED valores reparados. Panel reiniciado."
    warn "Recarga el panel con Ctrl+F5"
else
    log "Todo correcto - no faltaba ningun valor."
fi
