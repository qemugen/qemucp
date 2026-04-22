#!/bin/bash
# ============================================================
# QemuCP - Importador de Backup Oficial cPanel
# Version: 1.2
# Uso: bash cpanel-import.sh /ruta/backup_cpanel.tar.gz [usuario_destino]
# Importa: ficheros web, bases de datos MySQL, correo, DNS
# ============================================================

set -euo pipefail

BACKUP="${1:-}"
FORCE_USER="${2:-}"
HESTIA="/usr/local/hestia"
BIN="$HESTIA/bin"
LOG="/var/log/qemucp-cpanel-import.log"
WORK_DIR=""
CREDS_FILE="/root/qemucp-import-credentials.txt"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG"; }
error()  { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG"; [[ -n "$WORK_DIR" ]] && rm -rf "$WORK_DIR"; exit 1; }
header() { echo -e "\n${BLUE}========================================${NC}" | tee -a "$LOG"
           echo -e "${BLUE} $1${NC}" | tee -a "$LOG"
           echo -e "${BLUE}========================================${NC}" | tee -a "$LOG"; }
info()   { echo -e "  -> $1" | tee -a "$LOG"; }

# -- Validaciones ------------------------------------------------
[[ $EUID -ne 0 ]] && error "Ejecuta como root"
[[ -z "$BACKUP" ]] && error "Uso: bash cpanel-import.sh /ruta/backup.tar.gz [usuario_destino]"
[[ ! -f "$BACKUP" ]] && error "Fichero no encontrado: $BACKUP"
[[ ! -f "$HESTIA/conf/hestia.conf" ]] && error "QemuCP no instalado"

echo "" >> "$CREDS_FILE"
echo "=== Importacion $(date) ===" >> "$CREDS_FILE"
echo "QemuCP cPanel Import - $(date)" > "$LOG"
header "QemuCP - Importador de Backup cPanel"
log "Backup: $BACKUP ($(du -sh "$BACKUP" | cut -f1))"

# -- Descomprimir ------------------------------------------------
header "Descomprimiendo backup"
WORK_DIR=$(mktemp -d /tmp/cpanel-import-XXXXXX)
tar -xzf "$BACKUP" -C "$WORK_DIR" 2>/dev/null || error "Error descomprimiendo backup"

# Detectar directorio raiz
BACKUP_PATH="$WORK_DIR"
FIRST=$(ls "$WORK_DIR" | head -1)
[[ -d "$WORK_DIR/$FIRST" && $(ls "$WORK_DIR" | wc -l) -eq 1 ]] && BACKUP_PATH="$WORK_DIR/$FIRST"
log "Raiz del backup: $BACKUP_PATH"
log "Contenido: $(ls "$BACKUP_PATH" | tr '\n' ' ')"

# -- Detectar usuario cPanel ------------------------------------
# Fuente 1: fichero cp/username
CPANEL_USER=""
[[ -f "$BACKUP_PATH/cp/username" ]] && \
    CPANEL_USER=$(cat "$BACKUP_PATH/cp/username" | tr -d ' \n\r')

# Fuente 2: nombre del fichero (varios formatos de cPanel)
if [[ -z "$CPANEL_USER" ]]; then
    FILENAME=$(basename "$BACKUP" .tar.gz)
    # Formato cPanel estandar: backup-M.D.YYYY_HH-MM-SS_usuario
    CPANEL_USER=$(echo "$FILENAME" | sed 's/^backup-[0-9.]*_[0-9-]*_//')
    # Formato cpbackup: cpbackup-YYYY-MM-DD_usuario
    [[ "$CPANEL_USER" == "$FILENAME" ]] &&         CPANEL_USER=$(echo "$FILENAME" | sed 's/^cpbackup-[0-9-]*_//')
    # Si sigue sin cambiar, coger la ultima parte despues del ultimo _
    [[ "$CPANEL_USER" == "$FILENAME" ]] &&         CPANEL_USER=$(echo "$FILENAME" | awk -F_ '{print $NF}')
fi

# Limpiar: minusculas, solo alfanumerico y guion bajo
CPANEL_USER=$(echo "$CPANEL_USER" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_')
CPANEL_USER=$(echo "$CPANEL_USER" | sed 's/^_*//;s/_*$//')
[[ -n "$FORCE_USER" ]] && CPANEL_USER="$FORCE_USER"
[[ -z "$CPANEL_USER" ]] && error "No se pudo detectar el usuario. Usa: bash cpanel-import.sh backup.tar.gz usuario"

log "Usuario detectado: $CPANEL_USER"

# -- Crear usuario en QemuCP ------------------------------------
header "Creando usuario en QemuCP"

if $BIN/v-list-user "$CPANEL_USER" &>/dev/null 2>&1; then
    warn "Usuario $CPANEL_USER ya existe en QemuCP - se importaran datos sobre el existente"
else
    USER_PASS=$(openssl rand -base64 12 | tr -d '/+=')
    USER_EMAIL=$(cat "$BACKUP_PATH/cp/contactemail" 2>/dev/null ||                  cat "$BACKUP_PATH/cp/email" 2>/dev/null ||                  echo "")
    USER_EMAIL=$(echo "$USER_EMAIL" | tr -d ' 

' | head -c 100)

    # Validar email - si no tiene formato valido usar uno generado
    if [[ -z "$USER_EMAIL" ]] || ! echo "$USER_EMAIL" | grep -qP '^[^@]+@[^@]+\.[^@]+$'; then
        USER_EMAIL="${CPANEL_USER}@${MAIN_DOMAIN:-example.com}"
        warn "Email no encontrado, usando: $USER_EMAIL"
    fi

    $BIN/v-add-user "$CPANEL_USER" "$USER_PASS" "$USER_EMAIL" "default" \
        2>/dev/null && log "Usuario $CPANEL_USER creado" || \
        error "No se pudo crear el usuario $CPANEL_USER"

    echo "Usuario panel: $CPANEL_USER | Pass: $USER_PASS | Email: $USER_EMAIL" >> "$CREDS_FILE"
fi

# -- Detectar dominios ------------------------------------------
header "Detectando dominios"

MAIN_DOMAIN=""
ADDON_DOMAINS=()
SUB_DOMAINS=()

# Dominio principal desde cp/ o userdata/main
if [[ -f "$BACKUP_PATH/cp/main_domain" ]]; then
    MAIN_DOMAIN=$(cat "$BACKUP_PATH/cp/main_domain" | tr -d ' \n\r')
elif [[ -f "$BACKUP_PATH/userdata/main" ]]; then
    MAIN_DOMAIN=$(grep "^main_domain:" "$BACKUP_PATH/userdata/main" 2>/dev/null | \
        awk '{print $2}' | tr -d '"' | tr -d ' \n\r' || true)
fi

log "Dominio principal: ${MAIN_DOMAIN:-no detectado}"

# Addon domains desde addons/
if [[ -d "$BACKUP_PATH/addons" ]]; then
    while IFS='=' read -r addon_domain docroot; do
        addon_domain=$(echo "$addon_domain" | tr -d ' \n\r')
        [[ -n "$addon_domain" && "$addon_domain" =~ ^[a-z0-9] ]] && \
            ADDON_DOMAINS+=("$addon_domain")
    done < <(cat "$BACKUP_PATH/addons" 2>/dev/null || true)
fi

# Addon domains desde userdata/ (ficheros individuales por dominio)
if [[ -d "$BACKUP_PATH/userdata" ]]; then
    for f in "$BACKUP_PATH/userdata"/*/; do
        domain=$(basename "$f")
        # Ignorar ficheros de metadatos
        [[ "$domain" == "main" ]] && continue
        [[ "$domain" =~ _SSL$ ]] && continue
        [[ "$domain" == "$MAIN_DOMAIN" ]] && continue
        # Validar formato de dominio
        if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]; then
            ADDON_DOMAINS+=("$domain")
        fi
    done
fi

# Subdominios
if [[ -f "$BACKUP_PATH/sds" ]] || [[ -f "$BACKUP_PATH/sds2" ]]; then
    while IFS= read -r line; do
        sub=$(echo "$line" | awk -F= '{print $1}' | tr -d ' ')
        [[ -n "$sub" && "$sub" =~ \. ]] && SUB_DOMAINS+=("$sub")
    done < <(cat "$BACKUP_PATH/sds" "$BACKUP_PATH/sds2" 2>/dev/null || true)
fi

# Eliminar duplicados
ADDON_DOMAINS=($(printf '%s\n' "${ADDON_DOMAINS[@]}" | sort -u))
log "Addon domains: ${ADDON_DOMAINS[*]:-ninguno}"
log "Subdominios: ${SUB_DOMAINS[*]:-ninguno}"

# -- Crear dominios web -----------------------------------------
header "Creando dominios web"

# Obtener IP real del servidor registrada en QemuCP
SERVER_IP=$($BIN/v-list-ips plain 2>/dev/null | awk '{print $1}' | grep -v "^$" | head -1 || true)
[[ -z "$SERVER_IP" ]] && SERVER_IP=$(hostname -I | awk '{print $1}' || true)
[[ -z "$SERVER_IP" ]] && SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || true)
[[ -z "$SERVER_IP" ]] && error "No se pudo detectar la IP del servidor"
log "IP del servidor: $SERVER_IP"

create_domain() {
    local user="$1"
    local domain="$2"
    # Validar formato
    if [[ ! "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]; then
        warn "Formato invalido, saltando: $domain"
        return
    fi
    if $BIN/v-list-web-domain "$user" "$domain" &>/dev/null 2>&1; then
        warn "Dominio $domain ya existe"
    else
        $BIN/v-add-web-domain "$user" "$domain" "$SERVER_IP" "yes" \
            2>/dev/null && log "Dominio $domain creado" || \
            warn "No se pudo crear $domain"
    fi
}

[[ -n "$MAIN_DOMAIN" ]] && create_domain "$CPANEL_USER" "$MAIN_DOMAIN"
for D in "${ADDON_DOMAINS[@]}"; do create_domain "$CPANEL_USER" "$D"; done
for D in "${SUB_DOMAINS[@]}"; do create_domain "$CPANEL_USER" "$D"; done

# -- Ficheros web -----------------------------------------------
header "Importando ficheros web"

HOMEDIR="$BACKUP_PATH/homedir"
if [[ -d "$HOMEDIR" ]]; then
    DEST_HOME="/home/$CPANEL_USER"

    # public_html -> dominio principal
    if [[ -n "$MAIN_DOMAIN" && -d "$HOMEDIR/public_html" ]]; then
        DEST_WEB="$DEST_HOME/web/$MAIN_DOMAIN/public_html"
        mkdir -p "$DEST_WEB" 2>/dev/null || true
        rsync -a --exclude='*.log' --exclude='.htaccess.bak' \
            "$HOMEDIR/public_html/" "$DEST_WEB/" 2>/dev/null && \
            log "public_html copiado a $DEST_WEB" || \
            warn "Error parcial copiando public_html"
        chown -R "$CPANEL_USER:$CPANEL_USER" "$DEST_WEB" 2>/dev/null || true
    fi

    # Carpetas de addon domains dentro de homedir
    for ADDON in "${ADDON_DOMAINS[@]}"; do
        # cPanel guarda addons como public_html/addon_subdir o directo en home
        for POSSIBLE in \
            "$HOMEDIR/$ADDON" \
            "$HOMEDIR/public_html/$ADDON" \
            "$HOMEDIR/${ADDON%%.*}"; do
            if [[ -d "$POSSIBLE" ]]; then
                DEST_ADDON="$DEST_HOME/web/$ADDON/public_html"
                mkdir -p "$DEST_ADDON" 2>/dev/null || true
                rsync -a --exclude='*.log' "$POSSIBLE/" "$DEST_ADDON/" 2>/dev/null && \
                    log "Addon $ADDON copiado" || warn "Error copiando addon $ADDON"
                chown -R "$CPANEL_USER:$CPANEL_USER" "$DEST_ADDON" 2>/dev/null || true
                break
            fi
        done
    done
else
    warn "No se encontro homedir/ en el backup"
fi

# -- Bases de datos MySQL ---------------------------------------
header "Importando bases de datos MySQL"

# cPanel guarda los dumps en mysql/ con nombre usuario_dbname.sql o .sql.gz
MYSQL_DIR=""
for D in "mysql" "mysql_databases" "mysql_dump"; do
    [[ -d "$BACKUP_PATH/$D" ]] && MYSQL_DIR="$BACKUP_PATH/$D" && break
done

# Tambien puede haber un mysql.sql unico
if [[ -z "$MYSQL_DIR" && -f "$BACKUP_PATH/mysql.sql" ]]; then
    MYSQL_DIR="$BACKUP_PATH"
fi

if [[ -n "$MYSQL_DIR" ]]; then
    for SQL_FILE in "$MYSQL_DIR"/*.sql.gz "$MYSQL_DIR"/*.sql; do
        [[ -f "$SQL_FILE" ]] || continue
        # Ignorar mysql.sql-auth.json y similares
        [[ "$SQL_FILE" == *"-auth"* ]] && continue
        [[ "$SQL_FILE" == *"mysql.sql" && "$MYSQL_DIR" == "$BACKUP_PATH" ]] && continue

        DB_BASENAME=$(basename "$SQL_FILE" .sql.gz)
        DB_BASENAME=$(basename "$DB_BASENAME" .sql)
        DB_CLEAN=$(echo "$DB_BASENAME" | sed "s/^${CPANEL_USER}_//")
        DB_FINAL="${CPANEL_USER}_${DB_CLEAN}"
        DB_PASS=$(openssl rand -base64 12 | tr -d '/+=')

        info "DB: $DB_BASENAME -> $DB_FINAL"

        if ! $BIN/v-list-database "$CPANEL_USER" "$DB_FINAL" &>/dev/null 2>&1; then
            $BIN/v-add-database "$CPANEL_USER" "$DB_CLEAN" "$DB_CLEAN" \
                "$DB_PASS" "mysql" "localhost" \
                2>/dev/null && log "  DB $DB_FINAL creada" || \
                warn "  No se pudo crear DB $DB_FINAL"
            echo "DB: $DB_FINAL | User: ${CPANEL_USER}_${DB_CLEAN} | Pass: $DB_PASS" >> "$CREDS_FILE"
        fi

        if [[ "$SQL_FILE" == *.gz ]]; then
            gunzip -c "$SQL_FILE" | mysql "$DB_FINAL" 2>/dev/null && \
                log "  Datos importados en $DB_FINAL" || warn "  Error importando $DB_FINAL"
        else
            mysql "$DB_FINAL" < "$SQL_FILE" 2>/dev/null && \
                log "  Datos importados en $DB_FINAL" || warn "  Error importando $DB_FINAL"
        fi
    done
else
    warn "No se encontro directorio mysql/ en el backup"
fi

# -- Correo -----------------------------------------------------
header "Importando correo"

# cPanel guarda el correo en homedir/mail/
MAIL_BASE=""
for D in "$BACKUP_PATH/homedir/mail" "$BACKUP_PATH/mail"; do
    [[ -d "$D" ]] && MAIL_BASE="$D" && break
done

if [[ -n "$MAIL_BASE" ]]; then
    log "Directorio de correo: $MAIL_BASE"
    for DOMAIN_DIR in "$MAIL_BASE"/*/; do
        [[ -d "$DOMAIN_DIR" ]] || continue
        MAIL_DOMAIN=$(basename "$DOMAIN_DIR")
        # Ignorar directorios internos de cPanel
        [[ "$MAIL_DOMAIN" == "etc" ]] && continue
        [[ "$MAIL_DOMAIN" == "new" ]] && continue
        [[ "$MAIL_DOMAIN" == "cur" ]] && continue
        [[ "$MAIL_DOMAIN" == "tmp" ]] && continue

        info "Dominio mail: $MAIL_DOMAIN"

        if ! $BIN/v-list-mail-domain "$CPANEL_USER" "$MAIL_DOMAIN" &>/dev/null 2>&1; then
            $BIN/v-add-mail-domain "$CPANEL_USER" "$MAIL_DOMAIN" \
                2>/dev/null && log "  Dominio mail $MAIL_DOMAIN creado" || \
                warn "  No se pudo crear dominio mail $MAIL_DOMAIN"
        fi

        # Leer shadow de cPanel para importar hashes sin resetear passwords
        # cPanel guarda hashes en homedir/etc/DOMINIO/shadow
        CPANEL_SHADOW="$BACKUP_PATH/homedir/etc/$MAIL_DOMAIN/shadow"
        HESTIA_PASSWD="/etc/exim4/domains/$MAIL_DOMAIN/passwd"
        declare -A SHADOW_HASHES
        if [[ -f "$CPANEL_SHADOW" ]]; then
            while IFS=: read -r acc hash rest; do
                [[ -n "$acc" && -n "$hash" && "$hash" != "!!" && "$hash" != "*" ]] &&                     SHADOW_HASHES["$acc"]="$hash"
            done < "$CPANEL_SHADOW"
            log "  Shadow leido: ${#SHADOW_HASHES[@]} hashes encontrados"
        fi

        # Cuentas de correo
        for ACCOUNT_DIR in "$DOMAIN_DIR"*/; do
            [[ -d "$ACCOUNT_DIR" ]] || continue
            ACCOUNT=$(basename "$ACCOUNT_DIR")
            [[ "$ACCOUNT" == "." || "$ACCOUNT" == ".." ]] && continue
            [[ "$ACCOUNT" == "new" || "$ACCOUNT" == "cur" || "$ACCOUNT" == "tmp" ]] && continue

            # Crear cuenta con password temporal
            MAIL_PASS=$(openssl rand -base64 10 | tr -d '/+=')
            $BIN/v-add-mail-account "$CPANEL_USER" "$MAIL_DOMAIN" \
                "$ACCOUNT" "$MAIL_PASS" \
                2>/dev/null && log "  $ACCOUNT@$MAIL_DOMAIN creada" || \
                warn "  No se pudo crear $ACCOUNT@$MAIL_DOMAIN"

            # Si tenemos hash original de cPanel, restaurarlo directamente
            if [[ -n "${SHADOW_HASHES[$ACCOUNT]:-}" ]]; then
                HASH="${SHADOW_HASHES[$ACCOUNT]}"
                # Detectar tipo y anadir prefijo Dovecot
                if [[ "$HASH" == '$6$'* ]]; then
                    DOVECOT_HASH="{SHA512-CRYPT}$HASH"
                elif [[ "$HASH" == '$1$'* ]]; then
                    DOVECOT_HASH="{MD5-CRYPT}$HASH"
                elif [[ "$HASH" == '$5$'* ]]; then
                    DOVECOT_HASH="{SHA256-CRYPT}$HASH"
                else
                    DOVECOT_HASH="{CRYPT}$HASH"
                fi
                # Sobreescribir en passwd de HestiaCP con formato completo
                # Formato: usuario:hash:owner:mail::/home/owner:0:userdb_quota_rule=*:storage=0M
                if [[ -f "$HESTIA_PASSWD" ]]; then
                    sed -i "s|^${ACCOUNT}:.*|${ACCOUNT}:${DOVECOT_HASH}:${CPANEL_USER}:mail::/home/${CPANEL_USER}:0:userdb_quota_rule=*:storage=0M|" \
                        "$HESTIA_PASSWD" 2>/dev/null && \
                        log "  Password original restaurada para $ACCOUNT" || \
                        warn "  No se pudo restaurar password de $ACCOUNT"
                fi
            else
                # Sin hash original - guardar nueva password
                echo "Mail: $ACCOUNT@$MAIL_DOMAIN | Pass: $MAIL_PASS (nueva)" >> "$CREDS_FILE"
                warn "  Sin hash para $ACCOUNT - password nueva: $MAIL_PASS"
            fi

            # Copiar correos existentes (Maildir)
            DEST_MAIL="/home/$CPANEL_USER/mail/$MAIL_DOMAIN/$ACCOUNT"
            if [[ -d "$DEST_MAIL" ]]; then
                rsync -a "$ACCOUNT_DIR/" "$DEST_MAIL/" 2>/dev/null && \
                    log "  Correos de $ACCOUNT copiados" || \
                    warn "  Error copiando correos de $ACCOUNT"
                chown -R "$CPANEL_USER:mail" "$DEST_MAIL" 2>/dev/null || true
            fi
        done
        unset SHADOW_HASHES
    done
else
    warn "No se encontro directorio de correo en el backup"
fi

# -- DNS --------------------------------------------------------
header "Importando DNS"

# cPanel usa dnszones/ no dns/
DNS_BASE=""
for D in "$BACKUP_PATH/dnszones" "$BACKUP_PATH/dns"; do
    [[ -d "$D" ]] && DNS_BASE="$D" && break
done

if [[ -n "$DNS_BASE" ]]; then
    for ZONE_FILE in "$DNS_BASE"/*.db; do
        [[ -f "$ZONE_FILE" ]] || continue
        ZONE_DOMAIN=$(basename "$ZONE_FILE" .db)
        if ! $BIN/v-list-dns-domain "$CPANEL_USER" "$ZONE_DOMAIN" &>/dev/null 2>&1; then
            $BIN/v-add-dns-domain "$CPANEL_USER" "$ZONE_DOMAIN" "$SERVER_IP" \
                2>/dev/null && log "Zona DNS $ZONE_DOMAIN creada" || \
                warn "No se pudo crear zona DNS $ZONE_DOMAIN"
        else
            warn "Zona DNS $ZONE_DOMAIN ya existe"
        fi
    done
else
    warn "No se encontro directorio dnszones/ en el backup"
fi

# -- SSL --------------------------------------------------------
header "Configurando SSL"

ALL_DOMAINS=()
[[ -n "$MAIN_DOMAIN" ]] && ALL_DOMAINS+=("$MAIN_DOMAIN")
ALL_DOMAINS+=("${ADDON_DOMAINS[@]}")

for DOMAIN in "${ALL_DOMAINS[@]}"; do
    [[ -z "$DOMAIN" ]] && continue
    $BIN/v-add-letsencrypt-domain "$CPANEL_USER" "$DOMAIN" "" "yes" \
        2>/dev/null && log "SSL activado para $DOMAIN" || \
        warn "SSL pendiente para $DOMAIN (DNS debe apuntar a este servidor)"
done

# -- Limpieza ---------------------------------------------------
rm -rf "$WORK_DIR"

# -- Resumen ----------------------------------------------------
header "IMPORTACION COMPLETADA"
echo ""
log "Usuario: $CPANEL_USER"
log "Dominio principal: ${MAIN_DOMAIN:-ninguno}"
log "Addon domains: ${ADDON_DOMAINS[*]:-ninguno}"
log "Credenciales en: $CREDS_FILE"
log "Log completo en: $LOG"
echo ""
warn "Actualiza las cadenas de conexion a DB en tus aplicaciones"
warn "Apunta los DNS de tus dominios a este servidor"
echo ""
