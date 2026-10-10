#!/bin/bash
# ============================================================
# QemuCP Migrator - Exportador Universal
# Soporta: cPanel, Plesk
# Uso: bash qemucp-export.sh [cpanel|plesk] [usuario|usuario1,usuario2|all]
#
# cPanel: genera las copias oficiales (pkgacct) de las cuentas; se importan
# en QemuCP con cpanel-import-lote.sh. Plesk: exportacion basica (sin probar
# en CI: revisar el resultado).
# ============================================================

set -euo pipefail

PANEL="${1:-auto}"
USER_FILTER="${2:-all}"
EXPORT_DIR="${EXPORT_DIR:-/home/qemucp-migration-$(date +%Y%m%d_%H%M%S)}"
LOG="$EXPORT_DIR/migration.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()   { echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG"; }
error() { echo -e "${RED}[!!]${NC} $1" | tee -a "$LOG"; exit 1; }
header(){ echo -e "\n${GREEN}=== $1 ===${NC}" | tee -a "$LOG"; }

[[ $EUID -ne 0 ]] && error "Ejecuta como root"

mkdir -p "$EXPORT_DIR"/{users,domains,databases,mail,dns,ssl,files}
echo "QemuCP Migration Export - $(date)" > "$LOG"

# -- Auto-detectar panel -------------------------------------
if [ "$PANEL" = "auto" ]; then
    if [ -d /var/cpanel ] || [ -f /usr/local/cpanel/cpanel ]; then
        PANEL="cpanel"
    elif [ -d /opt/psa ] || [ -f /usr/local/psa/version ]; then
        PANEL="plesk"
    else
        error "No se pudo detectar cPanel ni Plesk. Especifica: bash qemucp-export.sh [cpanel|plesk]"
    fi
fi

log "Panel detectado: $PANEL"
log "Directorio de exportacion: $EXPORT_DIR"

# ============================================================
# EXPORTACION cPANEL
# ============================================================
export_cpanel() {
    # Para cPanel se usa su copia oficial (pkgacct): lleva todo lo que el
    # importador de QemuCP necesita (tipos de dominio, contrasenas de correo,
    # reenviadores, zonas, crons, SSL...). La exportacion "a mano" que habia
    # aqui perdia subdominios, contrasenas y registros DNS.
    header "Exportando desde cPanel (copias oficiales pkgacct)"
    [[ -x /scripts/pkgacct ]] || error "No esta /scripts/pkgacct: ¿es un servidor cPanel/WHM con acceso root?"
    if [ "$USER_FILTER" = "all" ]; then
        USERS=$(ls /var/cpanel/users/ 2>/dev/null | grep -v "^root$" | grep -v "^system$" || true)
    else
        USERS="${USER_FILTER//,/ }"
    fi
    BK_DIR="$EXPORT_DIR/cpanel"
    mkdir -p "$BK_DIR"
    LIBRE=$(df -Pm "$BK_DIR" | awk 'NR==2 {print $4}')
    TOTAL=0
    for CUSER in $USERS; do
        [[ -f /var/cpanel/users/$CUSER ]] || { warn "No existe la cuenta cPanel $CUSER"; continue; }
        TOTAL=$(( TOTAL + $(du -sm "/home/$CUSER" 2>/dev/null | cut -f1 || echo 0) ))
    done
    [[ "$LIBRE" -gt "$TOTAL" ]] || error "Espacio libre en $EXPORT_DIR: ${LIBRE}MB; las cuentas ocupan ~${TOTAL}MB. Usa: EXPORT_DIR=/otro/disco"
    N=0
    for CUSER in $USERS; do
        [[ -f /var/cpanel/users/$CUSER ]] || continue
        log "Copia de $CUSER..."
        if /scripts/pkgacct --skipbwdata "$CUSER" "$BK_DIR" >> "$LOG" 2>&1; then
            N=$((N+1))
        else
            warn "  pkgacct fallo para $CUSER (ver $LOG)"
        fi
    done
    log "$N copias en $BK_DIR"
    echo ""
    echo "Siguiente paso - en el servidor QemuCP:"
    echo "  rsync -av root@$(hostname -f 2>/dev/null || hostname):$BK_DIR/ /root/backups-cpanel/"
    echo "  bash cpanel-import-lote.sh /root/backups-cpanel [plan]"
    echo ""
    echo "Para renombrar cuentas o dar planes distintos, usa una lista:"
    echo "  echo '/root/backups-cpanel/cpmove-pepe.tar.gz pepe2 plan_basico' > lista.txt"
    echo "  bash cpanel-import-lote.sh lista.txt"
    exit 0
}

# ============================================================
# EXPORTACION PLESK
# ============================================================
export_plesk() {
    header "Exportando desde Plesk"

    PLESK_BIN="/usr/local/psa/bin"
    [[ ! -d "$PLESK_BIN" ]] && PLESK_BIN="/opt/psa/bin"
    [[ ! -d "$PLESK_BIN" ]] && error "No se encontro el binario de Plesk"

    # Obtener clientes
    if [ "$USER_FILTER" = "all" ]; then
        CLIENTS=$("$PLESK_BIN/client" --list 2>/dev/null | awk '{print $1}' | tail -n +2 || true)
    else
        CLIENTS="$USER_FILTER"
    fi

    for CLIENT in $CLIENTS; do
        [[ -z "$CLIENT" ]] && continue
        log "Exportando cliente Plesk: $CLIENT"

        CLIENT_DIR="$EXPORT_DIR/users/$CLIENT"
        mkdir -p "$CLIENT_DIR"

        # Info del cliente
        "$PLESK_BIN/client" --info "$CLIENT" 2>/dev/null | python3 << PYEOF
import sys, json, re

content = sys.stdin.read()
data = {}
for line in content.split('\n'):
    if ':' in line:
        k, _, v = line.partition(':')
        data[k.strip().lower().replace(' ', '_')] = v.strip()

user_info = {
    'username': '$CLIENT',
    'email':    data.get('email', '${CLIENT}@localhost'),
    'name':     data.get('contact_name', '$CLIENT'),
    'source':   'plesk',
}
with open('$CLIENT_DIR/user.json', 'w') as f:
    json.dump(user_info, f, indent=2)
print(f"  Cliente exportado: {user_info['email']}")
PYEOF

        # Dominios del cliente
        mkdir -p "$CLIENT_DIR/domains"
        "$PLESK_BIN/domain" --list --client "$CLIENT" 2>/dev/null | \
            tail -n +2 | awk '{print $1}' > "$CLIENT_DIR/domains/domains.txt" || true

        python3 << PYEOF
import json
domains = []
try:
    with open('$CLIENT_DIR/domains/domains.txt') as f:
        domains = [l.strip() for l in f if l.strip()]
except:
    pass
with open('$CLIENT_DIR/domains/domains.json', 'w') as f:
    json.dump({'domains': domains, 'subdomains': []}, f, indent=2)
print(f"  Dominios: {domains}")
PYEOF

        # Bases de datos
        mkdir -p "$CLIENT_DIR/databases"
        while read DOMAIN; do
            [[ -z "$DOMAIN" ]] && continue
            "$PLESK_BIN/database" --list --domain "$DOMAIN" 2>/dev/null | \
                tail -n +2 | awk '{print $1}' | while read DB; do
                [[ -z "$DB" ]] && continue
                log "  Exportando DB Plesk: $DB"
                mysqldump --single-transaction "$DB" \
                    > "$CLIENT_DIR/databases/${DB}.sql" 2>/dev/null || \
                    warn "  No se pudo exportar $DB"
            done
        done < "$CLIENT_DIR/domains/domains.txt" 2>/dev/null || true

        # Email accounts
        mkdir -p "$CLIENT_DIR/mail"
        python3 << PYEOF
import subprocess, json, os

domains = []
try:
    with open('$CLIENT_DIR/domains/domains.txt') as f:
        domains = [l.strip() for l in f if l.strip()]
except:
    pass

mail_data = {}
for domain in domains:
    try:
        result = subprocess.run(
            ['$PLESK_BIN/mail', '--list', '--domain', domain],
            capture_output=True, text=True
        )
        accounts = [l.split()[0] for l in result.stdout.split('\n')[1:] if l.strip()]
        mail_data[domain] = accounts
    except:
        mail_data[domain] = []

with open('$CLIENT_DIR/mail/accounts.json', 'w') as f:
    json.dump(mail_data, f, indent=2)
print(f"  Email domains: {list(mail_data.keys())}")
PYEOF

        # SSL
        mkdir -p "$CLIENT_DIR/ssl"
        while read DOMAIN; do
            [[ -z "$DOMAIN" ]] && continue
            CERT_DIR="$CLIENT_DIR/ssl/$DOMAIN"
            mkdir -p "$CERT_DIR"
            "$PLESK_BIN/certificate" --info "$DOMAIN" 2>/dev/null | \
                grep -A100 "BEGIN CERTIFICATE" > "$CERT_DIR/cert.pem" 2>/dev/null || true
        done < "$CLIENT_DIR/domains/domains.txt" 2>/dev/null || true

        # Ficheros web
        HOMEDIR=$("$PLESK_BIN/client" --info "$CLIENT" 2>/dev/null | grep -i "home\|httpdocs" | head -1 | awk '{print $NF}' || echo "/var/www/vhosts")
        echo "rsync -avz $HOMEDIR/ DESTUSER@DESTSERVER:/home/$CLIENT/" \
            > "$CLIENT_DIR/rsync_command.sh"
        chmod +x "$CLIENT_DIR/rsync_command.sh"

        log "Cliente $CLIENT exportado correctamente"
    done
}

# -- Ejecutar exportacion -------------------------------------
case "$PANEL" in
    cpanel) export_cpanel ;;
    plesk)  export_plesk  ;;
    *)      error "Panel no reconocido: $PANEL (usa cpanel o plesk)" ;;
esac

# -- Crear archivo comprimido ---------------------------------
header "Creando paquete de migracion"
PACKAGE="/tmp/qemucp-migration-$(date +%Y%m%d_%H%M%S).tar.gz"
tar -czf "$PACKAGE" -C /tmp "$(basename $EXPORT_DIR)" 2>/dev/null

echo ""
log "Exportacion completada"
log "Paquete: $PACKAGE"
log "Tamanio: $(du -sh $PACKAGE | cut -f1)"
echo ""
echo "Siguiente paso - en el servidor QemuCP:"
echo "  scp root@ORIGEN:$PACKAGE /tmp/"
echo "  bash qemucp-import.sh $PACKAGE"
