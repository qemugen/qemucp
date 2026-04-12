#!/bin/bash
# ============================================================
# QemuCP Migrator - Exportador Universal
# Soporta: cPanel, Plesk
# Uso: bash qemucp-export.sh [cpanel|plesk] [usuario|all]
# ============================================================

set -euo pipefail

PANEL="${1:-auto}"
USER_FILTER="${2:-all}"
EXPORT_DIR="/tmp/qemucp-migration-$(date +%Y%m%d_%H%M%S)"
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
    header "Exportando desde cPanel"

    # Obtener lista de usuarios
    if [ "$USER_FILTER" = "all" ]; then
        USERS=$(ls /var/cpanel/users/ 2>/dev/null | grep -v "^root$" || true)
    else
        USERS="$USER_FILTER"
    fi

    for CUSER in $USERS; do
        [[ ! -f /var/cpanel/users/$CUSER ]] && continue
        log "Exportando usuario: $CUSER"

        USER_DIR="$EXPORT_DIR/users/$CUSER"
        mkdir -p "$USER_DIR"

        # Datos del usuario
        python3 << PYEOF
import re, json

with open("/var/cpanel/users/$CUSER") as f:
    content = f.read()

data = {}
for line in content.split('\n'):
    if '=' in line:
        k, _, v = line.partition('=')
        data[k.strip()] = v.strip()

user_info = {
    'username': '$CUSER',
    'email':    data.get('CONTACTEMAIL', '${CUSER}@localhost'),
    'password': data.get('ENCTYPE', 'sha-512') + ':' + data.get('PASSWORD', ''),
    'plan':     data.get('PLAN', 'default'),
    'source':   'cpanel',
}

with open('$USER_DIR/user.json', 'w') as f:
    json.dump(user_info, f, indent=2)
print(f"  Usuario exportado: {user_info['email']}")
PYEOF

        # Dominios web
        mkdir -p "$USER_DIR/domains"
        if [ -f /var/cpanel/userdata/$CUSER/main ]; then
            python3 << PYEOF
import yaml, json, os, re

try:
    import yaml
    with open("/var/cpanel/userdata/$CUSER/main") as f:
        data = yaml.safe_load(f)
    domains = data.get('addon_domains', {})
    domains[data.get('main_domain', '')] = ''
    sub = data.get('sub_domains', [])
except:
    domains = {}
    sub = []

result = {'domains': list(domains.keys()), 'subdomains': sub if isinstance(sub, list) else []}
with open('$USER_DIR/domains/domains.json', 'w') as f:
    json.dump(result, f, indent=2)
print(f"  Dominios: {list(domains.keys())}")
PYEOF
        fi

        # Bases de datos MySQL
        mkdir -p "$USER_DIR/databases"
        if command -v mysql &>/dev/null; then
            mysql -e "SHOW DATABASES LIKE '${CUSER}%';" 2>/dev/null | tail -n +2 | while read DB; do
                log "  Exportando DB: $DB"
                mysqldump --single-transaction --routines --triggers \
                    "$DB" > "$USER_DIR/databases/${DB}.sql" 2>/dev/null || \
                    warn "  No se pudo exportar $DB"
            done

            # Usuarios de DB y sus grants
            mysql -e "SELECT User, Host, authentication_string FROM mysql.user WHERE User LIKE '${CUSER}_%';" \
                2>/dev/null > "$USER_DIR/databases/db_users.txt" || true
        fi

        # Cuentas de email
        mkdir -p "$USER_DIR/mail"
        if [ -d /home/$CUSER/mail ]; then
            python3 << PYEOF
import os, json

mail_data = {}
mail_base = "/home/$CUSER/mail"

if os.path.isdir(mail_base):
    for domain in os.listdir(mail_base):
        domain_path = os.path.join(mail_base, domain)
        if os.path.isdir(domain_path):
            mail_data[domain] = []
            for account in os.listdir(domain_path):
                if os.path.isdir(os.path.join(domain_path, account)):
                    mail_data[domain].append(account)

with open("$USER_DIR/mail/accounts.json", "w") as f:
    json.dump(mail_data, f, indent=2)
print(f"  Dominios de email: {list(mail_data.keys())}")
PYEOF
        fi

        # Passwords de email desde shadow
        if [ -f /etc/vdomainpasswd ]; then
            grep "^${CUSER}" /etc/vdomainpasswd > "$USER_DIR/mail/passwords.txt" 2>/dev/null || true
        fi

        # DNS zones
        mkdir -p "$USER_DIR/dns"
        if [ -d /var/named ]; then
            for ZONE in $(ls /var/named/${CUSER}*.db 2>/dev/null); do
                cp "$ZONE" "$USER_DIR/dns/" 2>/dev/null || true
            done
        fi
        # cPanel DNS alternativo
        if [ -d /var/cpanel/zone ]; then
            find /var/cpanel/zone -name "*.db" 2>/dev/null | while read Z; do
                cp "$Z" "$USER_DIR/dns/" 2>/dev/null || true
            done
        fi

        # SSL certificates
        mkdir -p "$USER_DIR/ssl"
        if [ -d /etc/letsencrypt/live ]; then
            for CERTDIR in /etc/letsencrypt/live/*/; do
                DOMAIN=$(basename "$CERTDIR")
                mkdir -p "$USER_DIR/ssl/$DOMAIN"
                cp "$CERTDIR"*.pem "$USER_DIR/ssl/$DOMAIN/" 2>/dev/null || true
            done
        fi

        # Ficheros web (lista para rsync posterior)
        echo "rsync -avz /home/$CUSER/ DESTUSER@DESTSERVER:/home/$CUSER/" \
            > "$USER_DIR/rsync_command.sh"
        chmod +x "$USER_DIR/rsync_command.sh"

        log "Usuario $CUSER exportado correctamente"
    done
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
