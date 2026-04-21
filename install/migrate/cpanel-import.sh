#!/bin/bash
# ============================================================
# QemuCP - Importador de Backup Oficial cPanel
# Uso: bash cpanel-import.sh /ruta/backup_cpanel.tar.gz
# Importa: ficheros web, bases de datos MySQL, correo
# ============================================================

set -euo pipefail

BACKUP="${1:-}"
HESTIA="/usr/local/hestia"
BIN="$HESTIA/bin"
LOG="/var/log/qemucp-cpanel-import.log"
WORK_DIR=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()    { echo -e "${GREEN}[OK]${NC} $1" | tee -a "$LOG"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1" | tee -a "$LOG"; }
error()  { echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG"; exit 1; }
header() { echo -e "\n${BLUE}========================================${NC}" | tee -a "$LOG"
           echo -e "${BLUE} $1${NC}" | tee -a "$LOG"
           echo -e "${BLUE}========================================${NC}" | tee -a "$LOG"; }
info()   { echo -e "  ${YELLOW}->$NC $1" | tee -a "$LOG"; }

# -- Validaciones iniciales -----------------------------------
[[ $EUID -ne 0 ]] && error "Ejecuta como root"
[[ -z "$BACKUP" ]] && error "Uso: bash cpanel-import.sh /ruta/backup.tar.gz"
[[ ! -f "$BACKUP" ]] && error "Fichero no encontrado: $BACKUP"
[[ ! -f "$HESTIA/conf/hestia.conf" ]] && error "QemuCP no instalado"

echo "QemuCP cPanel Import - $(date)" > "$LOG"
header "QemuCP - Importador de Backup cPanel"
log "Backup: $BACKUP"
log "Tamanio: $(du -sh "$BACKUP" | cut -f1)"

# -- Descomprimir ---------------------------------------------
header "Descomprimiendo backup"
WORK_DIR=$(mktemp -d /tmp/cpanel-import-XXXXXX)
log "Directorio temporal: $WORK_DIR"

tar -xzf "$BACKUP" -C "$WORK_DIR" 2>/dev/null || \
    error "No se pudo descomprimir. Verifica que sea un backup cPanel valido."

# Detectar directorio raiz del backup
BACKUP_ROOT=$(ls "$WORK_DIR" | head -1)
BACKUP_PATH="$WORK_DIR/$BACKUP_ROOT"

# Si el tar extrae directamente sin subcarpeta
if [[ ! -d "$BACKUP_PATH" ]]; then
    BACKUP_PATH="$WORK_DIR"
fi

log "Estructura del backup detectada en: $BACKUP_PATH"

# -- Detectar usuario del backup ------------------------------
# En cPanel el backup se llama backup-FECHA_HORA_USUARIO.tar.gz
CPANEL_USER=$(basename "$BACKUP" | grep -oP '(?<=_)[a-z0-9]+(?=\.tar)' || \
              cat "$BACKUP_PATH/cp/username" 2>/dev/null || \
              basename "$BACKUP_PATH")
CPANEL_USER=$(echo "$CPANEL_USER" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')

log "Usuario cPanel detectado: $CPANEL_USER"

# Verificar si el usuario ya existe en QemuCP
if $BIN/v-list-user "$CPANEL_USER" &>/dev/null 2>&1; then
    warn "El usuario $CPANEL_USER ya existe en QemuCP"
    echo ""
    read -p "Continuar de todas formas? Los datos existentes podrian sobreescribirse. (s/N): " CONFIRM
    [[ "$CONFIRM" != "s" && "$CONFIRM" != "S" ]] && exit 0
else
    # Crear usuario en QemuCP
    header "Creando usuario"
    USER_PASS=$(openssl rand -base64 12 | tr -d '/+=')
    USER_EMAIL=$(cat "$BACKUP_PATH/cp/email" 2>/dev/null || echo "${CPANEL_USER}@localhost")
    USER_EMAIL=$(echo "$USER_EMAIL" | tr -d ' \n')

    $BIN/v-add-user "$CPANEL_USER" "$USER_PASS" "$USER_EMAIL" "default" \
        2>/dev/null && log "Usuario $CPANEL_USER creado (pass: $USER_PASS)" || \
        warn "Error creando usuario - puede que ya exista"

    # Guardar credenciales
    echo "Usuario: $CPANEL_USER" >> /root/qemucp-import-credentials.txt
    echo "Password panel: $USER_PASS" >> /root/qemucp-import-credentials.txt
    echo "Email: $USER_EMAIL" >> /root/qemucp-import-credentials.txt
    echo "---" >> /root/qemucp-import-credentials.txt
fi

# -- Dominios web ---------------------------------------------
header "Importando dominios web"

# Obtener dominio principal desde userdata
MAIN_DOMAIN=""
if [[ -f "$BACKUP_PATH/userdata/main" ]]; then
    MAIN_DOMAIN=$(grep "^main_domain:" "$BACKUP_PATH/userdata/main" 2>/dev/null | \
        awk '{print $2}' | tr -d '"' || true)
fi

# Fallback: buscar en cp/
if [[ -z "$MAIN_DOMAIN" ]] && [[ -f "$BACKUP_PATH/cp/main_domain" ]]; then
    MAIN_DOMAIN=$(cat "$BACKUP_PATH/cp/main_domain" 2>/dev/null | tr -d ' \n')
fi

# Obtener todos los dominios (principal + addon)
DOMAINS=()
[[ -n "$MAIN_DOMAIN" ]] && DOMAINS+=("$MAIN_DOMAIN")

# Addon domains
if [[ -f "$BACKUP_PATH/userdata/main" ]]; then
    while IFS= read -r line; do
        domain=$(echo "$line" | grep -oP '^[a-z0-9._-]+(?=:)' || true)
        [[ -n "$domain" && "$domain" != "main_domain" && "$domain" != "$MAIN_DOMAIN" ]] && \
            DOMAINS+=("$domain")
    done < <(grep -E "^[a-z0-9._-]+:" "$BACKUP_PATH/userdata/main" 2>/dev/null || true)
fi

log "Dominios encontrados: ${DOMAINS[*]:-ninguno}"

for DOMAIN in "${DOMAINS[@]}"; do
    [[ -z "$DOMAIN" ]] && continue
    info "Procesando dominio: $DOMAIN"

    if $BIN/v-list-web-domain "$CPANEL_USER" "$DOMAIN" &>/dev/null 2>&1; then
        warn "  Dominio $DOMAIN ya existe, saltando creacion"
    else
        $BIN/v-add-web-domain "$CPANEL_USER" "$DOMAIN" "0.0.0.0" "yes" \
            2>/dev/null && log "  Dominio $DOMAIN creado" || \
            warn "  No se pudo crear $DOMAIN"
    fi
done

# -- Ficheros web ---------------------------------------------
header "Importando ficheros web"

HOMEDIR="$BACKUP_PATH/homedir"
if [[ -d "$HOMEDIR" ]]; then
    DEST_HOME="/home/$CPANEL_USER"

    # Copiar public_html
    if [[ -d "$HOMEDIR/public_html" ]]; then
        DEST_WEB="$DEST_HOME/web/$MAIN_DOMAIN/public_html"
        if [[ -d "$DEST_WEB" ]]; then
            log "Copiando ficheros web a $DEST_WEB"
            rsync -a --exclude='*.log' \
                "$HOMEDIR/public_html/" "$DEST_WEB/" 2>/dev/null && \
                log "Ficheros web copiados" || \
                warn "Error parcial copiando ficheros web"
            chown -R "$CPANEL_USER:$CPANEL_USER" "$DEST_WEB" 2>/dev/null || true
        else
            warn "Directorio destino no existe: $DEST_WEB"
        fi
    fi

    # Copiar subdominios / addon domains
    for SUBDIR in "$HOMEDIR"/*/; do
        SUBNAME=$(basename "$SUBDIR")
        [[ "$SUBNAME" == "public_html" ]] && continue
        [[ "$SUBNAME" == "mail" ]] && continue
        [[ "$SUBNAME" == "etc" ]] && continue

        DEST_ADDON="$DEST_HOME/web/$SUBNAME/public_html"
        if [[ -d "$DEST_ADDON" ]]; then
            rsync -a --exclude='*.log' \
                "$SUBDIR" "$DEST_ADDON/" 2>/dev/null && \
                log "Addon $SUBNAME copiado" || \
                warn "Error copiando addon $SUBNAME"
            chown -R "$CPANEL_USER:$CPANEL_USER" "$DEST_ADDON" 2>/dev/null || true
        fi
    done
else
    warn "No se encontro homedir/ en el backup"
fi

# -- Bases de datos MySQL --------------------------------------
header "Importando bases de datos MySQL"

DB_DIR="$BACKUP_PATH/mysql"
if [[ -d "$DB_DIR" ]]; then
    for SQL_FILE in "$DB_DIR"/*.sql.gz "$DB_DIR"/*.sql; do
        [[ -f "$SQL_FILE" ]] || continue

        # Nombre de la DB
        DB_BASENAME=$(basename "$SQL_FILE" .sql.gz)
        DB_BASENAME=$(basename "$DB_BASENAME" .sql)

        # En cPanel el nombre de DB tiene prefijo usuario_
        DB_CLEAN=$(echo "$DB_BASENAME" | sed "s/^${CPANEL_USER}_//")
        DB_FINAL="${CPANEL_USER}_${DB_CLEAN}"
        DB_USER="${CPANEL_USER}_${DB_CLEAN}"
        DB_PASS=$(openssl rand -base64 12 | tr -d '/+=')

        info "Procesando DB: $DB_BASENAME -> $DB_FINAL"

        # Crear DB en QemuCP
        if $BIN/v-list-database "$CPANEL_USER" "$DB_FINAL" &>/dev/null 2>&1; then
            warn "  DB $DB_FINAL ya existe"
        else
            $BIN/v-add-database "$CPANEL_USER" "$DB_CLEAN" "$DB_CLEAN" \
                "$DB_PASS" "mysql" "localhost" \
                2>/dev/null && log "  DB $DB_FINAL creada (user: $DB_USER pass: $DB_PASS)" || \
                warn "  No se pudo crear DB $DB_FINAL"

            echo "DB: $DB_FINAL | User: $DB_USER | Pass: $DB_PASS" >> \
                /root/qemucp-import-credentials.txt
        fi

        # Importar datos
        if [[ "$SQL_FILE" == *.gz ]]; then
            gunzip -c "$SQL_FILE" | mysql "$DB_FINAL" 2>/dev/null && \
                log "  Datos importados en $DB_FINAL" || \
                warn "  Error importando datos en $DB_FINAL"
        else
            mysql "$DB_FINAL" < "$SQL_FILE" 2>/dev/null && \
                log "  Datos importados en $DB_FINAL" || \
                warn "  Error importando datos en $DB_FINAL"
        fi
    done
else
    warn "No se encontro directorio mysql/ en el backup"
fi

# -- Correo ----------------------------------------------------
header "Importando cuentas de correo"

MAIL_DIR="$BACKUP_PATH/mail"
if [[ -d "$MAIL_DIR" ]]; then
    for DOMAIN_DIR in "$MAIL_DIR"/*/; do
        MAIL_DOMAIN=$(basename "$DOMAIN_DIR")
        [[ -z "$MAIL_DOMAIN" ]] && continue

        info "Dominio de correo: $MAIL_DOMAIN"

        # Crear dominio de correo si no existe
        if ! $BIN/v-list-mail-domain "$CPANEL_USER" "$MAIL_DOMAIN" &>/dev/null 2>&1; then
            $BIN/v-add-mail-domain "$CPANEL_USER" "$MAIL_DOMAIN" \
                2>/dev/null && log "  Dominio mail $MAIL_DOMAIN creado" || \
                warn "  No se pudo crear dominio mail $MAIL_DOMAIN"
        fi

        # Crear cuentas de correo
        for ACCOUNT_DIR in "$DOMAIN_DIR"*/; do
            [[ -d "$ACCOUNT_DIR" ]] || continue
            ACCOUNT=$(basename "$ACCOUNT_DIR")
            [[ "$ACCOUNT" == "." || "$ACCOUNT" == ".." ]] && continue

            MAIL_PASS=$(openssl rand -base64 10 | tr -d '/+=')

            $BIN/v-add-mail-account "$CPANEL_USER" "$MAIL_DOMAIN" \
                "$ACCOUNT" "$MAIL_PASS" \
                2>/dev/null && log "  Cuenta $ACCOUNT@$MAIL_DOMAIN creada (pass: $MAIL_PASS)" || \
                warn "  No se pudo crear $ACCOUNT@$MAIL_DOMAIN"

            echo "Mail: $ACCOUNT@$MAIL_DOMAIN | Pass: $MAIL_PASS" >> \
                /root/qemucp-import-credentials.txt

            # Copiar correos existentes (Maildir)
            DEST_MAIL="/home/$CPANEL_USER/mail/$MAIL_DOMAIN/$ACCOUNT"
            if [[ -d "$DEST_MAIL" ]] && [[ -d "$ACCOUNT_DIR" ]]; then
                rsync -a "$ACCOUNT_DIR/" "$DEST_MAIL/" 2>/dev/null && \
                    log "  Correos de $ACCOUNT copiados" || \
                    warn "  Error copiando correos de $ACCOUNT"
                chown -R "$CPANEL_USER:mail" "$DEST_MAIL" 2>/dev/null || true
            fi
        done
    done
else
    warn "No se encontro directorio mail/ en el backup"
fi

# -- DNS -------------------------------------------------------
header "Importando zonas DNS"

DNS_DIR="$BACKUP_PATH/dns"
if [[ -d "$DNS_DIR" ]]; then
    for ZONE_FILE in "$DNS_DIR"/*.db; do
        [[ -f "$ZONE_FILE" ]] || continue
        ZONE_DOMAIN=$(basename "$ZONE_FILE" .db)

        if ! $BIN/v-list-dns-domain "$CPANEL_USER" "$ZONE_DOMAIN" &>/dev/null 2>&1; then
            $BIN/v-add-dns-domain "$CPANEL_USER" "$ZONE_DOMAIN" "0.0.0.0" \
                2>/dev/null && log "Zona DNS $ZONE_DOMAIN creada" || \
                warn "No se pudo crear zona DNS $ZONE_DOMAIN"
        else
            warn "Zona DNS $ZONE_DOMAIN ya existe"
        fi
    done
else
    warn "No se encontro directorio dns/ en el backup"
fi

# -- SSL -------------------------------------------------------
header "Configurando SSL"

for DOMAIN in "${DOMAINS[@]}"; do
    [[ -z "$DOMAIN" ]] && continue
    info "Intentando SSL Let's Encrypt para $DOMAIN"
    $BIN/v-add-letsencrypt-domain "$CPANEL_USER" "$DOMAIN" "" "yes" \
        2>/dev/null && log "SSL activado para $DOMAIN" || \
        warn "SSL pendiente para $DOMAIN (asegurate de que el DNS apunta a este servidor)"
done

# -- Limpieza --------------------------------------------------
header "Limpieza"
rm -rf "$WORK_DIR"
log "Directorio temporal eliminado"

# -- Resumen ---------------------------------------------------
header "IMPORTACION COMPLETADA"
echo ""
echo "Usuario QemuCP:  $CPANEL_USER"
echo "Dominios:        ${DOMAINS[*]:-ninguno}"
echo ""
log "Credenciales guardadas en: /root/qemucp-import-credentials.txt"
log "Log completo en: $LOG"
echo ""
warn "IMPORTANTE: Revisa y actualiza las cadenas de conexion a DB en tus aplicaciones"
warn "IMPORTANTE: Apunta los registros DNS de tus dominios a este servidor"
warn "IMPORTANTE: Verifica que los correos se reciben correctamente"
echo ""
