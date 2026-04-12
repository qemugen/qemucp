#!/bin/bash
# ============================================================
# QemuCP Migrator - Importador
# Uso: bash qemucp-import.sh /tmp/qemucp-migration-XXXX.tar.gz
# ============================================================

set -euo pipefail

PACKAGE="${1:-}"
HESTIA="/usr/local/hestia"
BIN="$HESTIA/bin"
LOG="/var/log/qemucp-migration.log"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()    { echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG"; }
error()  { echo -e "${RED}[!!]${NC} $1" | tee -a "$LOG"; exit 1; }
header() { echo -e "\n${BLUE}=== $1 ===${NC}" | tee -a "$LOG"; }
skip()   { echo -e "${YELLOW}[SKIP]${NC} $1" | tee -a "$LOG"; }

[[ $EUID -ne 0 ]] && error "Ejecuta como root"
[[ ! -f "$HESTIA/conf/hestia.conf" ]] && error "QemuCP no instalado"
[[ -z "$PACKAGE" ]] && error "Uso: bash qemucp-import.sh /ruta/al/paquete.tar.gz"
[[ ! -f "$PACKAGE" ]] && error "Paquete no encontrado: $PACKAGE"

echo "QemuCP Migration Import - $(date)" > "$LOG"
header "QemuCP Migrador - Importacion"
log "Paquete: $PACKAGE"

# Descomprimir
WORK_DIR=$(mktemp -d)
tar -xzf "$PACKAGE" -C "$WORK_DIR" 2>/dev/null
MIGRATION_DIR=$(ls "$WORK_DIR" | head -1)
MIGRATION_PATH="$WORK_DIR/$MIGRATION_DIR"

log "Directorio de trabajo: $MIGRATION_PATH"

# -- Resumen de lo que se va a importar ----------------------
USERS=$(ls "$MIGRATION_PATH/users/" 2>/dev/null || true)
echo ""
echo "Usuarios a importar:"
for U in $USERS; do echo "  - $U"; done
echo ""
read -p "Continuar- (s/N): " CONFIRM
[[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]] && exit 0

# -- Importar cada usuario -----------------------------------
for USER_DIR in "$MIGRATION_PATH/users"/*/; do
    USERNAME=$(basename "$USER_DIR")
    [[ -z "$USERNAME" ]] && continue

    header "Importando usuario: $USERNAME"

    # Leer datos del usuario
    if [ ! -f "$USER_DIR/user.json" ]; then
        warn "No se encontro user.json para $USERNAME, saltando"
        continue
    fi

    USER_EMAIL=$(python3 -c "import json; d=json.load(open('$USER_DIR/user.json')); print(d.get('email','admin@localhost'))")
    USER_SOURCE=$(python3 -c "import json; d=json.load(open('$USER_DIR/user.json')); print(d.get('source','unknown'))")
    USER_PASS=$(openssl rand -base64 16)

    log "Email: $USER_EMAIL | Origen: $USER_SOURCE"

    # Crear usuario en QemuCP
    if $BIN/v-list-user "$USERNAME" &>/dev/null 2>&1; then
        skip "Usuario $USERNAME ya existe"
    else
        $BIN/v-add-user "$USERNAME" "$USER_PASS" "$USER_EMAIL" "default" \
            2>/dev/null && log "Usuario $USERNAME creado (pass: $USER_PASS)" || \
            warn "No se pudo crear usuario $USERNAME"
    fi

    # -- Dominios web ------------------------------------------
    if [ -f "$USER_DIR/domains/domains.json" ]; then
        header "  Dominios web de $USERNAME"

        python3 << PYEOF
import json, subprocess, sys

with open("$USER_DIR/domains/domains.json") as f:
    data = json.load(f)

domains = data.get('domains', [])
subdomains = data.get('subdomains', [])

for domain in domains:
    domain = domain.strip()
    if not domain:
        continue
    
    # Verificar si ya existe
    r = subprocess.run(["$BIN/v-list-web-domain", "$USERNAME", domain],
                       capture_output=True)
    if r.returncode == 0:
        print(f"  SKIP: {domain} ya existe")
        continue
    
    # A-adir dominio
    r = subprocess.run(
        ["$BIN/v-add-web-domain", "$USERNAME", domain, "0.0.0.0", "yes"],
        capture_output=True
    )
    if r.returncode == 0:
        print(f"  OK: {domain} creado")
        # Intentar SSL con Let's Encrypt
        r2 = subprocess.run(
            ["$BIN/v-add-letsencrypt-domain", "$USERNAME", domain, "", "yes"],
            capture_output=True
        )
        if r2.returncode == 0:
            print(f"  OK: SSL Let's Encrypt para {domain}")
        else:
            print(f"  INFO: SSL pendiente para {domain} (DNS no apunta aun)")
    else:
        print(f"  WARN: No se pudo crear {domain}: {r.stderr.decode()[:80]}")
PYEOF
    fi

    # -- Bases de datos ----------------------------------------
    if [ -d "$USER_DIR/databases" ] && ls "$USER_DIR/databases"/*.sql &>/dev/null 2>&1; then
        header "  Bases de datos de $USERNAME"

        for SQL_FILE in "$USER_DIR/databases"/*.sql; do
            DB_NAME=$(basename "$SQL_FILE" .sql)
            # Sanitizar nombre (QemuCP a-ade prefijo usuario)
            DB_CLEAN=$(echo "$DB_NAME" | sed "s/^${USERNAME}_//")
            DB_FINAL="${USERNAME}_${DB_CLEAN}"
            DB_USER="${USERNAME}_${DB_CLEAN}"
            DB_PASS=$(openssl rand -base64 12 | tr -d '/+=')

            # Crear base de datos
            if $BIN/v-list-database "$USERNAME" "$DB_FINAL" &>/dev/null 2>&1; then
                skip "  DB $DB_FINAL ya existe"
            else
                $BIN/v-add-database "$USERNAME" "$DB_CLEAN" "$DB_CLEAN" \
                    "$DB_PASS" "mysql" "localhost" \
                    2>/dev/null && log "  DB $DB_FINAL creada (user: $DB_USER, pass: $DB_PASS)" || \
                    warn "  No se pudo crear DB $DB_FINAL"
            fi

            # Importar datos SQL
            if mysql "$DB_FINAL" < "$SQL_FILE" 2>/dev/null; then
                log "  Datos importados en $DB_FINAL"
            else
                warn "  Error importando $SQL_FILE en $DB_FINAL"
            fi

            # Guardar credenciales
            echo "$DB_FINAL | $DB_USER | $DB_PASS" >> "$MIGRATION_PATH/db_credentials.txt"
        done
    fi

    # -- Email -------------------------------------------------
    if [ -f "$USER_DIR/mail/accounts.json" ]; then
        header "  Cuentas de email de $USERNAME"

        python3 << PYEOF
import json, subprocess

with open("$USER_DIR/mail/accounts.json") as f:
    mail_data = json.load(f)

for domain, accounts in mail_data.items():
    domain = domain.strip()
    if not domain:
        continue

    # Crear dominio de email si no existe
    r = subprocess.run(["$BIN/v-list-mail-domain", "$USERNAME", domain],
                       capture_output=True)
    if r.returncode != 0:
        r = subprocess.run(
            ["$BIN/v-add-mail-domain", "$USERNAME", domain],
            capture_output=True
        )
        if r.returncode == 0:
            print(f"  OK: dominio email {domain}")
        else:
            print(f"  WARN: no se pudo crear dominio email {domain}")
            continue

    # Crear cuentas
    for account in accounts:
        account = account.strip()
        if not account:
            continue
        import secrets, string
        passwd = ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(12))
        r = subprocess.run(
            ["$BIN/v-add-mail-account", "$USERNAME", domain, account, passwd],
            capture_output=True
        )
        if r.returncode == 0:
            print(f"  OK: {account}@{domain} (pass: {passwd})")
            with open("$MIGRATION_PATH/mail_credentials.txt", "a") as f:
                f.write(f"{account}@{domain} | {passwd}\n")
        else:
            print(f"  WARN: no se pudo crear {account}@{domain}")
PYEOF
    fi

    # -- DNS ---------------------------------------------------
    if [ -d "$USER_DIR/dns" ] && ls "$USER_DIR/dns"/*.db &>/dev/null 2>&1; then
        header "  Zonas DNS de $USERNAME"
        for ZONE_FILE in "$USER_DIR/dns"/*.db; do
            ZONE_DOMAIN=$(basename "$ZONE_FILE" .db)
            if $BIN/v-list-dns-domain "$USERNAME" "$ZONE_DOMAIN" &>/dev/null 2>&1; then
                skip "  DNS $ZONE_DOMAIN ya existe"
            else
                $BIN/v-add-dns-domain "$USERNAME" "$ZONE_DOMAIN" \
                    2>/dev/null && log "  DNS $ZONE_DOMAIN creado" || \
                    warn "  No se pudo crear DNS $ZONE_DOMAIN"
            fi
        done
    fi

    # -- Ficheros web ------------------------------------------
    if [ -f "$USER_DIR/rsync_command.sh" ]; then
        header "  Ficheros web de $USERNAME"
        warn "Ficheros web: ejecuta manualmente el rsync desde el servidor origen:"
        cat "$USER_DIR/rsync_command.sh"
    fi

    log "Usuario $USERNAME importado"
    echo ""

done

# -- Resumen final --------------------------------------------
header "IMPORTACION COMPLETADA"
echo ""
echo "Credenciales generadas:"
echo "  Usuarios:  $MIGRATION_PATH/users/*/user.json (ver password en pantalla arriba)"
echo "  Bases de datos: $MIGRATION_PATH/db_credentials.txt"
echo "  Email:     $MIGRATION_PATH/mail_credentials.txt"
echo ""
echo "Log completo: $LOG"
echo ""
warn "IMPORTANTE: Actualiza las cadenas de conexion a DB en tu aplicacion"
warn "IMPORTANTE: Apunta los DNS de tus dominios a este servidor"
warn "IMPORTANTE: Ejecuta el rsync de ficheros desde el servidor origen"

# Limpieza
rm -rf "$WORK_DIR"
