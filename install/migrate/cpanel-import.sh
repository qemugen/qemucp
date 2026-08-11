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
DB_CREATED=()  # Array de "DB_FINAL:DB_USER:DB_PASS" creadas en esta ejecucion
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

# NOTA sobre tipos de dominio en cPanel:
#   - addon domain  -> tiene su propio docroot (carpeta web independiente)
#   - parked/alias  -> comparte el docroot del dominio principal
# Las entradas DNS1..DNSn de cp/USUARIO incluyen AMBOS tipos. Distinguimos
# despues comprobando si existe docroot propio; los que no lo tengan se
# crean como ALIAS del dominio principal (que es lo que son).
PARKED_DOMAINS=()

# FUENTE 1 (la mas fiable en backups cPanel clasicos): fichero cp/USUARIO
# Contiene DNS=dominio_principal y DNS1..DNSn=addon/parked domains
CP_USER_FILE="$BACKUP_PATH/cp/$CPANEL_USER"
if [[ -f "$CP_USER_FILE" ]]; then
    while IFS='=' read -r key val; do
        key=$(echo "$key" | tr -d ' \r')
        val=$(echo "$val" | tr -d ' \r')
        [[ -z "$val" ]] && continue
        # DNS = dominio principal; DNS1, DNS2... = adicionales
        if [[ "$key" =~ ^DNS[0-9]+$ ]]; then
            [[ "$val" == "$MAIN_DOMAIN" ]] && continue
            if [[ "$val" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]; then
                if [[ -n "$MAIN_DOMAIN" && "$val" == *".$MAIN_DOMAIN" ]]; then
                    SUB_DOMAINS+=("$val")
                else
                    ADDON_DOMAINS+=("$val")
                fi
            fi
        fi
    done < <(grep -E "^DNS[0-9]*=" "$CP_USER_FILE" 2>/dev/null || true)
fi

# FUENTE 2: zonas DNS del backup (dnszones/*.db) - respaldo fiable
if [[ -d "$BACKUP_PATH/dnszones" ]]; then
    for Z in "$BACKUP_PATH/dnszones"/*.db; do
        [[ -f "$Z" ]] || continue
        zdom=$(basename "$Z" .db)
        [[ "$zdom" == "$MAIN_DOMAIN" ]] && continue
        if [[ "$zdom" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]; then
            if [[ -n "$MAIN_DOMAIN" && "$zdom" == *".$MAIN_DOMAIN" ]]; then
                SUB_DOMAINS+=("$zdom")
            else
                ADDON_DOMAINS+=("$zdom")
            fi
        fi
    done
fi

# FUENTE 3: addons/
if [[ -d "$BACKUP_PATH/addons" ]]; then
    while IFS='=' read -r addon_domain docroot; do
        addon_domain=$(echo "$addon_domain" | tr -d ' \n\r')
        [[ -n "$addon_domain" && "$addon_domain" =~ ^[a-z0-9] ]] && \
            ADDON_DOMAINS+=("$addon_domain")
    done < <(cat "$BACKUP_PATH/addons" 2>/dev/null || true)
fi

# Dominios desde userdata/ (fuente mas fiable en backups cPanel EA4).
# userdata/ puede tener ENTRADAS como directorios o como ficheros por dominio.
if [[ -d "$BACKUP_PATH/userdata" ]]; then
    for f in "$BACKUP_PATH/userdata"/*; do
        domain=$(basename "$f")
        # Ignorar metadatos y ficheros SSL/cache
        [[ "$domain" == "main" ]] && continue
        [[ "$domain" =~ _SSL$ ]] && continue
        [[ "$domain" == "cache" ]] && continue
        [[ "$domain" == "$MAIN_DOMAIN" ]] && continue
        # Quitar extension .json si la tiene
        domain="${domain%.json}"
        # Validar formato de dominio
        if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]; then
            # Clasificar: si es X.MAINDOMAIN es subdominio; si no, addon
            if [[ -n "$MAIN_DOMAIN" && "$domain" == *".$MAIN_DOMAIN" ]]; then
                SUB_DOMAINS+=("$domain")
            else
                ADDON_DOMAINS+=("$domain")
            fi
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
# Deduplicar ambas listas y evitar que un dominio este en las dos
ADDON_DOMAINS=($(printf '%s\n' "${ADDON_DOMAINS[@]:-}" | sort -u))
SUB_DOMAINS=($(printf '%s\n' "${SUB_DOMAINS[@]:-}" | sort -u))
# Quitar de ADDON los que ya esten en SUB (un dominio no puede ser ambos)
if [[ ${#SUB_DOMAINS[@]} -gt 0 ]]; then
    NEW_ADDONS=()
    for a in "${ADDON_DOMAINS[@]:-}"; do
        skip=0
        for s in "${SUB_DOMAINS[@]:-}"; do [[ "$a" == "$s" ]] && skip=1 && break; done
        [[ $skip -eq 0 ]] && NEW_ADDONS+=("$a")
    done
    ADDON_DOMAINS=("${NEW_ADDONS[@]:-}")
fi
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

# Devuelve 0 si el dominio tiene docroot propio en el backup (addon real),
# 1 si no lo tiene (dominio aparcado / alias del principal).
# HOMEDIR debe estar definida ANTES de esta funcion (la usa para localizar
# los docroots dentro del backup). Se define aqui por si el bloque de
# importacion de ficheros aun no se ha ejecutado.
HOMEDIR="${HOMEDIR:-$BACKUP_PATH/homedir}"

domain_has_docroot() {
    local DOM="$1"
    for cand in "$BACKUP_PATH/userdata/$DOM" "$BACKUP_PATH/userdata/${DOM}.json"; do
        if [[ -f "$cand" ]]; then
            local DR
            DR=$(grep -a "documentroot:" "$cand" 2>/dev/null | head -1 | \
                 sed 's/.*documentroot: *//; s/ *$//' | tr -d '"')
            [[ -n "$DR" && -d "$HOMEDIR/${DR#/home/*/}" ]] && return 0
        fi
    done
    for POSSIBLE in "$HOMEDIR/$DOM" "$HOMEDIR/public_html/$DOM" \
                    "$HOMEDIR/${DOM%%.*}" "$HOMEDIR/public_html/${DOM%%.*}"; do
        [[ -d "$POSSIBLE" ]] && return 0
    done
    return 1
}

# Clasificar ANTES de crear: los dominios sin docroot propio son "parked"
# (alias del principal en cPanel) y NO deben crearse como dominios web
# independientes, sino anadirse como alias del dominio principal.
REAL_ADDONS=()
for ADDON in "${ADDON_DOMAINS[@]:-}"; do
    [[ -z "$ADDON" ]] && continue
    if domain_has_docroot "$ADDON"; then
        REAL_ADDONS+=("$ADDON")
    else
        PARKED_DOMAINS+=("$ADDON")
    fi
done
[[ ${#REAL_ADDONS[@]} -gt 0 ]] && log "Addon domains con web propia: ${REAL_ADDONS[*]}"
[[ ${#PARKED_DOMAINS[@]} -gt 0 ]] && log "Dominios aparcados (alias del principal): ${#PARKED_DOMAINS[@]}"

# Crear: principal + addons REALES + subdominios (los parked van como alias)
[[ -n "$MAIN_DOMAIN" ]] && create_domain "$CPANEL_USER" "$MAIN_DOMAIN"
for D in "${REAL_ADDONS[@]:-}"; do [[ -n "$D" ]] && create_domain "$CPANEL_USER" "$D"; done
for D in "${SUB_DOMAINS[@]:-}"; do [[ -n "$D" ]] && create_domain "$CPANEL_USER" "$D"; done

# Anadir los aparcados como ALIAS del dominio principal
if [[ ${#PARKED_DOMAINS[@]} -gt 0 && -n "$MAIN_DOMAIN" ]]; then
    for PK in "${PARKED_DOMAINS[@]}"; do
        [[ -z "$PK" ]] && continue
        $BIN/v-add-web-domain-alias "$CPANEL_USER" "$MAIN_DOMAIN" "$PK" no 2>/dev/null \
            && log "  Alias de $MAIN_DOMAIN: $PK" \
            || warn "  $PK: no se pudo anadir como alias"
    done
    $BIN/v-rebuild-web-domains "$CPANEL_USER" 2>/dev/null || true
fi

# -- Ficheros web -----------------------------------------------
header "Importando ficheros web"

HOMEDIR="${HOMEDIR:-$BACKUP_PATH/homedir}"
if [[ -d "$HOMEDIR" ]]; then
    DEST_HOME="/home/$CPANEL_USER"

    # public_html -> dominio principal
    if [[ -n "$MAIN_DOMAIN" && -d "$HOMEDIR/public_html" ]]; then
        DEST_WEB="$DEST_HOME/web/$MAIN_DOMAIN/public_html"
        mkdir -p "$DEST_WEB" 2>/dev/null || true
        rm -f "$DEST_WEB/index.html" "$DEST_WEB/robots.txt" 2>/dev/null || true
        # Eliminar index.html por defecto de QemuCP antes del rsync
        rm -f "$DEST_WEB/index.html" 2>/dev/null || true

        rsync -a --exclude='*.log' --exclude='.htaccess.bak'             "$HOMEDIR/public_html/" "$DEST_WEB/" 2>/dev/null &&             log "public_html copiado a $DEST_WEB" ||             warn "Error parcial copiando public_html"
        chown -R "$CPANEL_USER:$CPANEL_USER" "$DEST_WEB" 2>/dev/null || true
        chmod 755 "/home/$CPANEL_USER" 2>/dev/null || true
        chmod 755 "/home/$CPANEL_USER/web" 2>/dev/null || true
        chmod 755 "/home/$CPANEL_USER/web/$MAIN_DOMAIN" 2>/dev/null || true
        chmod 755 "$DEST_WEB" 2>/dev/null || true
        find "$DEST_WEB" -mindepth 0 -type d -exec chmod 755 {} + 2>/dev/null || true
        find "$DEST_WEB" -type f -exec chmod 644 {} + 2>/dev/null || true
        log "Permisos corregidos en $DEST_WEB"

        # Crear symlink /home/USER/public_html -> public_html
        # Necesario para apps con rutas hardcodeadas desde cPanel
        if [[ ! -e "/home/$CPANEL_USER/public_html" ]]; then
            ln -s "$DEST_WEB" "/home/$CPANEL_USER/public_html" 2>/dev/null &&                 log "Symlink public_html creado" || true
        fi
    fi

    # Carpetas de addon domains y subdominios.
    # cPanel guarda la ruta REAL del docroot en userdata/DOMINIO (campo
    # documentroot). Leerla es lo fiable; si no, se prueban rutas comunes.
    copy_domain_files() {
        local DOM="$1"
        local SRC=""
        # 1. Leer documentroot real desde userdata (formato EA4)
        local UD_FILE=""
        for cand in "$BACKUP_PATH/userdata/$DOM" "$BACKUP_PATH/userdata/${DOM}.json" \
                    "$BACKUP_PATH/userdata/${DOM}_SSL"; do
            [[ -f "$cand" ]] && { UD_FILE="$cand"; break; }
        done
        if [[ -n "$UD_FILE" ]]; then
            # documentroot: /home/user/public_html/addon o similar
            local DOCROOT
            DOCROOT=$(grep -a "documentroot:" "$UD_FILE" 2>/dev/null | head -1 | \
                sed 's/.*documentroot: *//; s/ *$//' | tr -d '"')
            if [[ -n "$DOCROOT" ]]; then
                # Convertir ruta absoluta del origen a ruta dentro del backup
                # /home/USUARIO/public_html/x -> $HOMEDIR/public_html/x
                local RELATIVE="${DOCROOT#/home/*/}"
                [[ -d "$HOMEDIR/$RELATIVE" ]] && SRC="$HOMEDIR/$RELATIVE"
            fi
        fi
        # 2. Fallback: rutas comunes si no se encontro via userdata
        if [[ -z "$SRC" ]]; then
            for POSSIBLE in "$HOMEDIR/$DOM" "$HOMEDIR/public_html/$DOM" \
                            "$HOMEDIR/${DOM%%.*}" "$HOMEDIR/public_html/${DOM%%.*}"; do
                [[ -d "$POSSIBLE" ]] && { SRC="$POSSIBLE"; break; }
            done
        fi
        if [[ -z "$SRC" ]]; then
            warn "No se encontro el docroot de $DOM (revisar manualmente)"
            return
        fi
        local DEST_DOM="$DEST_HOME/web/$DOM/public_html"
        mkdir -p "$DEST_DOM" 2>/dev/null || true
        rm -f "$DEST_DOM/index.html" "$DEST_DOM/robots.txt" 2>/dev/null || true
        if rsync -a --exclude='*.log' "$SRC/" "$DEST_DOM/" 2>/dev/null; then
            log "Ficheros de $DOM copiados (desde ${SRC#$HOMEDIR/})"
        else
            warn "Error parcial copiando $DOM"
        fi
        chown -R "$CPANEL_USER:$CPANEL_USER" "$DEST_DOM" 2>/dev/null || true
        chmod 755 "$DEST_DOM" 2>/dev/null || true
        find "$DEST_DOM" -type d -exec chmod 755 {} + 2>/dev/null || true
        find "$DEST_DOM" -type f -exec chmod 644 {} + 2>/dev/null || true
    }

    # Copiar ficheros solo de los addons REALES (los parked comparten el
    # public_html del principal, no tienen ficheros propios que copiar).
    for ADDON in "${REAL_ADDONS[@]:-}"; do [[ -n "$ADDON" ]] && copy_domain_files "$ADDON"; done
    for SUB in "${SUB_DOMAINS[@]:-}"; do [[ -n "$SUB" ]] && copy_domain_files "$SUB"; done


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
            DB_CREATED+=("${DB_FINAL}:${CPANEL_USER}_${DB_CLEAN}:${DB_PASS}")
        else
            # DB ya existe (re-migracion) - regenerar password para poder actualizar el CMS
            warn "  DB $DB_FINAL ya existe - regenerando password"
            $BIN/v-change-database-password "$CPANEL_USER" "$DB_FINAL" "$DB_PASS" \
                2>/dev/null && log "  Password de $DB_FINAL regenerada" || \
                warn "  No se pudo regenerar password de $DB_FINAL"
            echo "DB: $DB_FINAL | User: ${CPANEL_USER}_${DB_CLEAN} | Pass: $DB_PASS (regenerada)" >> "$CREDS_FILE"
            DB_CREATED+=("${DB_FINAL}:${CPANEL_USER}_${DB_CLEAN}:${DB_PASS}")
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

    # FORMATO ANTIGUO cPanel: la cuenta principal del dominio primario guarda
    # sus mensajes directamente en mail/{cur,new,tmp} (sin carpeta de dominio).
    # Se migra a la cuenta principal del dominio principal en QemuCP.
    if [[ -d "$MAIL_BASE/cur" || -d "$MAIL_BASE/new" ]] && [[ -n "$MAIN_DOMAIN" ]]; then
        MAIN_MAIL_DEST="/home/$CPANEL_USER/mail/$MAIN_DOMAIN/$CPANEL_USER"
        if [[ -d "$MAIN_MAIL_DEST" ]]; then
            rsync -a "$MAIL_BASE/cur" "$MAIL_BASE/new" "$MAIL_BASE/tmp" \
                "$MAIN_MAIL_DEST/" 2>/dev/null && \
                log "  Correo del buzon principal (formato antiguo) migrado" || true
            chown -R "$CPANEL_USER:mail" "$MAIN_MAIL_DEST" 2>/dev/null || true
        else
            warn "  Hay correo en formato antiguo pero no existe el buzon destino"
            warn "  Crea la cuenta $CPANEL_USER@$MAIN_DOMAIN y reejecuta si lo necesitas"
        fi
    fi

    for DOMAIN_DIR in "$MAIL_BASE"/*/; do
        [[ -d "$DOMAIN_DIR" ]] || continue
        MAIL_DOMAIN=$(basename "$DOMAIN_DIR")
        # Ignorar directorios internos de cPanel/Courier/Dovecot que NO son dominios
        case "$MAIL_DOMAIN" in
            etc|new|cur|tmp|.*|courierimapkeywords|courierimapuiddb|courierimapacl|\
            courierpop3dsizelist|maildirfolder|dovecot*|.Trash*|.Sent*|.Drafts*)
                continue ;;
        esac
        # Debe tener formato de dominio (con al menos un punto y TLD valido)
        if ! [[ "$MAIL_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]; then
            continue
        fi

        info "Dominio mail: $MAIL_DOMAIN"

        if ! $BIN/v-list-mail-domain "$CPANEL_USER" "$MAIL_DOMAIN" &>/dev/null 2>&1; then
            $BIN/v-add-mail-domain "$CPANEL_USER" "$MAIL_DOMAIN" \
                2>/dev/null && log "  Dominio mail $MAIL_DOMAIN creado" || \
                warn "  No se pudo crear dominio mail $MAIL_DOMAIN"
        fi

        # Leer shadow de cPanel para importar hashes sin resetear passwords
        # cPanel guarda hashes en homedir/etc/DOMINIO/shadow
        CPANEL_SHADOW="$BACKUP_PATH/homedir/etc/$MAIL_DOMAIN/shadow"
        HESTIA_PASSWD="/home/$CPANEL_USER/conf/mail/$MAIL_DOMAIN/passwd"
        declare -A SHADOW_HASHES=()
        if [[ -f "$CPANEL_SHADOW" ]]; then
            while IFS=: read -r acc hash rest; do
                [[ -z "$acc" ]] && continue
                [[ -z "$hash" ]] && continue
                [[ "$hash" == "!!" || "$hash" == "*" ]] && continue
                SHADOW_HASHES["$acc"]="$hash"
            done < "$CPANEL_SHADOW" || true
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
                    PREFIX="{SHA512-CRYPT}"
                elif [[ "$HASH" == '$1$'* ]]; then
                    PREFIX="{MD5-CRYPT}"
                elif [[ "$HASH" == '$5$'* ]]; then
                    PREFIX="{SHA256-CRYPT}"
                else
                    PREFIX="{CRYPT}"
                fi
                # Sobreescribir solo el campo del hash - buscar {BLF-CRYPT} generado por v-add-mail-account
                if [[ -f "$HESTIA_PASSWD" ]]; then
                    sed -i "s|^${ACCOUNT}:{BLF-CRYPT}[^:]*:|${ACCOUNT}:${PREFIX}${HASH}:|"                         "$HESTIA_PASSWD" 2>/dev/null &&                         log "  Password original restaurada para $ACCOUNT" ||                         warn "  No se pudo restaurar password de $ACCOUNT"
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
        SHADOW_HASHES=()

        # Corregir permisos de la CONFIG de correo (passwd, aliases) para Exim
        chmod 755 "/home/$CPANEL_USER/conf/mail/$MAIL_DOMAIN" 2>/dev/null || true
        find "/home/$CPANEL_USER/conf/mail/$MAIL_DOMAIN" -type d \
            -exec chmod 755 {} + 2>/dev/null || true
        find "/home/$CPANEL_USER/conf/mail/$MAIL_DOMAIN" -type f \
            -exec chmod 644 {} + 2>/dev/null || true

        # Corregir permisos del MAILDIR REAL (donde estan los mensajes).
        # Sin esto Dovecot da "Permission denied" al abrir los buzones.
        MAILDIR_DOM="/home/$CPANEL_USER/mail/$MAIL_DOMAIN"
        if [[ -d "$MAILDIR_DOM" ]]; then
            chown -R "$CPANEL_USER:mail" "$MAILDIR_DOM" 2>/dev/null || true
            find "$MAILDIR_DOM" -type d -exec chmod 755 {} + 2>/dev/null || true
            find "$MAILDIR_DOM" -type f -exec chmod 644 {} + 2>/dev/null || true
        fi
        log "  Permisos mail $MAIL_DOMAIN corregidos (config + maildir)"

        # -- Reenvios (forwarders) y alias de cPanel --------------------
        # cPanel los guarda en homedir/etc/DOMINIO/aliases con formato:
        #   cuenta: destino1,destino2
        CPANEL_ALIASES="$BACKUP_PATH/homedir/etc/$MAIL_DOMAIN/aliases"
        if [[ -f "$CPANEL_ALIASES" ]]; then
            FWD_COUNT=0
            while IFS=: read -r alias_acc alias_dest; do
                alias_acc=$(echo "$alias_acc" | tr -d ' \r')
                alias_dest=$(echo "$alias_dest" | tr -d ' \r')
                [[ -z "$alias_acc" || -z "$alias_dest" ]] && continue
                [[ "$alias_acc" == "*" ]] && continue   # catchall se trata aparte
                # Solo si la cuenta existe como buzon
                if $BIN/v-list-mail-account "$CPANEL_USER" "$MAIL_DOMAIN" "$alias_acc" &>/dev/null 2>&1; then
                    # Anadir cada destino como forward
                    IFS=',' read -ra DESTS <<< "$alias_dest"
                    for d in "${DESTS[@]:-}"; do
                        d=$(echo "$d" | tr -d ' ')
                        [[ -z "$d" ]] && continue
                        $BIN/v-add-mail-account-forward "$CPANEL_USER" "$MAIL_DOMAIN" \
                            "$alias_acc" "$d" 2>/dev/null && FWD_COUNT=$((FWD_COUNT+1)) || true
                    done
                fi
            done < "$CPANEL_ALIASES"
            [[ $FWD_COUNT -gt 0 ]] && log "  $FWD_COUNT reenvios importados"
        fi

        # -- Catchall (cuenta por defecto del dominio) ------------------
        if [[ -f "$CPANEL_ALIASES" ]]; then
            CATCHALL=$(grep "^\*:" "$CPANEL_ALIASES" 2>/dev/null | head -1 | cut -d: -f2- | tr -d ' \r')
            if [[ -n "$CATCHALL" && "$CATCHALL" != ":fail:"* && "$CATCHALL" != ":blackhole:"* ]]; then
                $BIN/v-add-mail-domain-catchall "$CPANEL_USER" "$MAIL_DOMAIN" "$CATCHALL" \
                    2>/dev/null && log "  Catchall configurado: $CATCHALL" || true
            fi
        fi
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

        # Importar registros personalizados del fichero de zona.
        # La zona nueva trae los registros por defecto (A, NS, MX propios);
        # anadimos los que el cliente tenia y no existen ya (MX externos,
        # TXT de verificacion/SPF/DKIM, CNAME, subdominios A, SRV...).
        REC_COUNT=0
        while read -r rname rttl rclass rtype rvalue; do
            # Saltar comentarios, directivas y lineas vacias
            [[ -z "${rname:-}" ]] && continue
            [[ "$rname" == \;* || "$rname" == '$'* ]] && continue
            [[ -z "${rtype:-}" ]] && continue
            # Solo tipos que interesa migrar
            case "$rtype" in
                A|AAAA|CNAME|MX|TXT|SRV|CAA|NS) ;;
                *) continue ;;
            esac
            # Normalizar nombre: quitar el dominio final y el punto
            rec_name="${rname%.}"
            rec_name="${rec_name%.$ZONE_DOMAIN}"
            [[ "$rec_name" == "$ZONE_DOMAIN" || "$rec_name" == "@" ]] && rec_name=""
            # Valor completo (puede tener espacios en TXT/MX/SRV)
            rec_val="$rvalue"
            [[ -z "$rec_val" ]] && continue
            # Saltar NS y A del propio dominio (ya los crea QemuCP)
            [[ "$rtype" == "NS" && -z "$rec_name" ]] && continue
            [[ "$rtype" == "A" && -z "$rec_name" ]] && continue
            # Prioridad para MX/SRV. IMPORTANTE: los ficheros de zona usan
            # tabulaciones o espacios indistintamente, por eso se separa con
            # awk (que maneja ambos) y NO con 'cut -d" "'.
            rec_prio=""
            if [[ "$rtype" == "MX" || "$rtype" == "SRV" ]]; then
                rec_prio=$(echo "$rec_val" | awk '{print $1}')
                rec_val=$(echo "$rec_val" | awk '{$1=""; sub(/^[ \t]+/,""); print}')
                # Validar: la prioridad debe ser numerica y el valor no vacio
                if ! [[ "$rec_prio" =~ ^[0-9]+$ ]] || [[ -z "$rec_val" ]]; then
                    continue
                fi
            fi
            # Limpiar espacios/tabulaciones sobrantes del valor
            rec_val=$(echo "$rec_val" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
            [[ -z "$rec_val" ]] && continue

            # Llamada: con prioridad solo para MX/SRV (pasar "" rompe la validacion)
            if [[ -n "$rec_prio" ]]; then
                # Escribimos el registro DIRECTAMENTE en el fichero de zona de
                # HestiaCP en lugar de llamar a v-add-dns-record. Ese comando,
                # aun con restart=no, ejecuta sort_dns_records +
                # update_domain_serial + rebuild_dns_domain_conf en CADA
                # llamada (~1-2s), lo que hacia que una zona de 35 registros
                # tardase mas de un minuto. Aqui acumulamos y reconstruimos
                # una sola vez por zona al final.
                ZONE_CONF="/usr/local/hestia/data/users/$CPANEL_USER/dns/${ZONE_DOMAIN}.conf"
                if [[ -f "$ZONE_CONF" ]]; then
                    NEXT_ID=$(( $(awk -F"ID='" '{print $2}' "$ZONE_CONF" 2>/dev/null \
                        | cut -d"'" -f1 | sort -n | tail -1) + 1 ))
                    [[ -z "$NEXT_ID" || "$NEXT_ID" -lt 1 ]] && NEXT_ID=1
                    NOW_T=$(date +'%T'); NOW_D=$(date +'%F')
                    printf "ID='%s' RECORD='%s' TYPE='%s' PRIORITY='%s' VALUE='%s' SUSPENDED='no' TIME='%s' DATE='%s'\n" \
                        "$NEXT_ID" "${rec_name:-@}" "$rtype" "$rec_prio" "$rec_val" "$NOW_T" "$NOW_D" \
                        >> "$ZONE_CONF" 2>/dev/null && REC_COUNT=$((REC_COUNT+1)) || true
                fi
            fi
        done < <(grep -v "^;" "$ZONE_FILE" 2>/dev/null | grep -v "^$" || true)
        # Reconstruir ESTA zona una sola vez (en vez de una vez por registro)
        if [[ $REC_COUNT -gt 0 ]]; then
            ZONE_CONF="/usr/local/hestia/data/users/$CPANEL_USER/dns/${ZONE_DOMAIN}.conf"
            [[ -f "$ZONE_CONF" ]] && chmod 660 "$ZONE_CONF" 2>/dev/null || true
            $BIN/v-rebuild-dns-domain "$CPANEL_USER" "$ZONE_DOMAIN" 'no' 2>/dev/null || true
            log "  $REC_COUNT registros DNS importados en $ZONE_DOMAIN"
        fi
    done
    # Reconstruir y reiniciar DNS UNA sola vez, al terminar todas las zonas
    $BIN/v-rebuild-dns-domains "$CPANEL_USER" 2>/dev/null || true
    $BIN/v-restart-dns 2>/dev/null || true
    log "DNS reconstruido y reiniciado (una sola vez)"
else
    warn "No se encontro directorio dnszones/ en el backup"
fi

# -- Ajustar open_basedir para rutas fuera de public_html -------
header "Ajustando open_basedir"

# Algunas apps (Moodle, PrestaShop antiguo) necesitan acceder a rutas
# fuera de public_html. Anadimos rutas comunes al open_basedir.
PHP_POOL_DIR="/etc/php"
for POOL_FILE in $(find "$PHP_POOL_DIR" -name "${CPANEL_USER}*" -o -name "*.conf" 2>/dev/null |     xargs grep -l "$CPANEL_USER" 2>/dev/null | head -5); do
    if grep -q "open_basedir" "$POOL_FILE" 2>/dev/null; then
        # Anadir home del usuario y tmp al open_basedir si no estan ya
        EXTRA_PATHS="/home/$CPANEL_USER/web:/home/$CPANEL_USER/tmp"
        if ! grep "open_basedir" "$POOL_FILE" | grep -q "/home/$CPANEL_USER/web"; then
            sed -i "s|php_admin_value\[open_basedir\] = .*|&:$EXTRA_PATHS|" "$POOL_FILE" 2>/dev/null || true
            log "open_basedir ampliado en $POOL_FILE"
        fi
    fi
done

# -- Detectar y asignar version PHP por dominio ---------------
header "Detectando version PHP de cada dominio"

# Detecta la version PHP de un dominio desde varias fuentes del backup cPanel
detect_php_version() {
    local DOMAIN="$1"
    local WEBROOT="$2"
    local VERSION=""

    # Fuente 1: .htaccess del dominio (AddHandler/AddType/SetHandler)
    if [[ -f "$WEBROOT/.htaccess" ]]; then
        # ea-php74, php74, php-74 -> 74
        VERSION=$(grep -iP "x-httpd-(ea-)?php[0-9]{2}" "$WEBROOT/.htaccess" 2>/dev/null |             grep -oP "php[0-9]{2}" | grep -oP "[0-9]{2}" | head -1)
    fi

    # Fuente 2: .user.ini o php.ini con referencia de version
    if [[ -z "$VERSION" && -f "$WEBROOT/.user.ini" ]]; then
        VERSION=$(grep -oP "php[0-9]{2}" "$WEBROOT/.user.ini" 2>/dev/null | grep -oP "[0-9]{2}" | head -1)
    fi

    # Fuente 3: userdata del backup (formato cPanel EA4)
    for UD in "$BACKUP_PATH/userdata/$DOMAIN" "$BACKUP_PATH/userdata/${DOMAIN}.json"; do
        if [[ -z "$VERSION" && -f "$UD" ]]; then
            # phpversion: "ea-php74" o "ea-php81"
            VERSION=$(grep -iP "phpversion" "$UD" 2>/dev/null |                 grep -oP "php[0-9]{2}" | grep -oP "[0-9]{2}" | head -1)
        fi
    done

    # Fuente 4: fichero cp/ del usuario
    if [[ -z "$VERSION" && -f "$BACKUP_PATH/cp/$CPANEL_USER" ]]; then
        VERSION=$(grep -iP "phpversion|php_version" "$BACKUP_PATH/cp/$CPANEL_USER" 2>/dev/null |             grep -oP "php[0-9]{2}" | grep -oP "[0-9]{2}" | head -1)
    fi

    # Convertir 74 -> 7_4, 81 -> 8_1
    if [[ -n "$VERSION" && ${#VERSION} -eq 2 ]]; then
        echo "PHP-${VERSION:0:1}_${VERSION:1:1}"
    else
        echo ""
    fi
}

# Aplicar version PHP a cada dominio
assign_php_version() {
    local DOMAIN="$1"
    local WEBROOT="/home/$CPANEL_USER/web/$DOMAIN/public_html"
    local PHP_TPL
    PHP_TPL=$(detect_php_version "$DOMAIN" "$WEBROOT")

    if [[ -n "$PHP_TPL" ]]; then
        # Verificar que la version existe en el sistema
        if [[ -d "/etc/php/${PHP_TPL#PHP-}" ]] ||            ls "$HESTIA/data/templates/web/php-fpm/${PHP_TPL}.tpl" &>/dev/null 2>&1; then
            $BIN/v-change-web-domain-backend-tpl "$CPANEL_USER" "$DOMAIN" "$PHP_TPL" "no"                 2>/dev/null && log "  $DOMAIN -> $PHP_TPL" ||                 warn "  No se pudo asignar $PHP_TPL a $DOMAIN"
        else
            warn "  $DOMAIN necesita $PHP_TPL pero no esta instalada - usando por defecto"
        fi
    else
        info "  $DOMAIN: version PHP no detectada, usando por defecto"
    fi
}

[[ -n "$MAIN_DOMAIN" ]] && assign_php_version "$MAIN_DOMAIN"
for ADDON in "${ADDON_DOMAINS[@]:-}"; do
    assign_php_version "$ADDON"
done

# -- Detectar y actualizar credenciales de CMS ----------------
header "Actualizando credenciales de CMS"

# Extrae el nombre de DB configurado en un fichero de config de CMS
get_config_dbname() {
    local FILE="$1"
    local TYPE="$2"
    case "$TYPE" in
        wordpress)  grep "DB_NAME" "$FILE" 2>/dev/null | grep -oP "define\(\s*['\"]DB_NAME['\"]\s*,\s*['\"]\K[^'\"]+" | head -1 ;;
        ps16)       grep "_DB_NAME_" "$FILE" 2>/dev/null | grep -oP "define\('_DB_NAME_',\s*'\K[^']+" | head -1 ;;
        ps17)       grep "database_name:" "$FILE" 2>/dev/null | awk -F: '{print $2}' | tr -d " '\"" | head -1 ;;
        joomla)     grep 'public \$db ' "$FILE" 2>/dev/null | grep -oP "=\s*'\K[^']+" | head -1 ;;
        whmcs)      grep '\$db_name' "$FILE" 2>/dev/null | grep -oP '=\s*["'"'"']\K[^"'"'"']+' | head -1 ;;
        opencart)   grep "DB_DATABASE" "$FILE" 2>/dev/null | grep -oP "'\K[^']+" | tail -1 ;;
        moodle)     grep 'CFG->dbname' "$FILE" 2>/dev/null | grep -oP "=\s*'\K[^']+" | head -1 ;;
        drupal)     grep -oP "'database'\s*=>\s*'\K[^']+" "$FILE" 2>/dev/null | head -1 ;;
        magento2)   grep -oP "'dbname'\s*=>\s*'\K[^']+" "$FILE" 2>/dev/null | head -1 ;;
        magento1)   grep -oP "<dbname><!\[CDATA\[\K[^\]]+" "$FILE" 2>/dev/null | head -1 ;;
        laravel)    grep "^DB_DATABASE=" "$FILE" 2>/dev/null | cut -d= -f2 | tr -d ' ' | head -1 ;;
        codeigniter) grep -oP "'database'\s*=>\s*'\K[^']+" "$FILE" 2>/dev/null | head -1 ;;
    esac
}

# Actualiza UN fichero de config concreto con las credenciales dadas
update_one_config() {
    local FILE="$1"
    local TYPE="$2"
    local DB="$3"
    local USER="$4"
    local PASS="$5"
    case "$TYPE" in
        wordpress)
            sed -i "s|define(\s*['\"]DB_NAME['\"].*|define('DB_NAME', '$DB');|" "$FILE" 2>/dev/null
            sed -i "s|define(\s*['\"]DB_USER['\"].*|define('DB_USER', '$USER');|" "$FILE" 2>/dev/null
            sed -i "s|define(\s*['\"]DB_PASSWORD['\"].*|define('DB_PASSWORD', '$PASS');|" "$FILE" 2>/dev/null ;;
        ps16)
            sed -i "s|define('_DB_NAME_'.*|define('_DB_NAME_', '$DB');|" "$FILE" 2>/dev/null
            sed -i "s|define('_DB_USER_'.*|define('_DB_USER_', '$USER');|" "$FILE" 2>/dev/null
            sed -i "s|define('_DB_PASSWD_'.*|define('_DB_PASSWD_', '$PASS');|" "$FILE" 2>/dev/null ;;
        ps17)
            sed -i "s|database_name:.*|database_name: $DB|" "$FILE" 2>/dev/null
            sed -i "s|database_user:.*|database_user: $USER|" "$FILE" 2>/dev/null
            sed -i "s|database_password:.*|database_password: $PASS|" "$FILE" 2>/dev/null ;;
        joomla)
            sed -i "s|public \$db =.*|public \$db = '$DB';|" "$FILE" 2>/dev/null
            sed -i "s|public \$user =.*|public \$user = '$USER';|" "$FILE" 2>/dev/null
            sed -i "s|public \$password =.*|public \$password = '$PASS';|" "$FILE" 2>/dev/null ;;
        whmcs)
            sed -i "s|\$db_name.*|\$db_name = \"$DB\";|" "$FILE" 2>/dev/null
            sed -i "s|\$db_username.*|\$db_username = \"$USER\";|" "$FILE" 2>/dev/null
            sed -i "s|\$db_password.*|\$db_password = \"$PASS\";|" "$FILE" 2>/dev/null ;;
        opencart)
            sed -i "s|define('DB_DATABASE'.*|define('DB_DATABASE', '$DB');|" "$FILE" 2>/dev/null
            sed -i "s|define('DB_USERNAME'.*|define('DB_USERNAME', '$USER');|" "$FILE" 2>/dev/null
            sed -i "s|define('DB_PASSWORD'.*|define('DB_PASSWORD', '$PASS');|" "$FILE" 2>/dev/null ;;
        moodle)
            sed -i "s|\$CFG->dbname.*|\$CFG->dbname   = '$DB';|" "$FILE" 2>/dev/null
            sed -i "s|\$CFG->dbuser.*|\$CFG->dbuser   = '$USER';|" "$FILE" 2>/dev/null
            sed -i "s|\$CFG->dbpass.*|\$CFG->dbpass   = '$PASS';|" "$FILE" 2>/dev/null ;;
        drupal|magento2|codeigniter)
            python3 -c "
import re
with open('$FILE') as f: c = f.read()
c = re.sub(r\"'(database|dbname)'(\s*)=>(\s*)'[^']*'\", r\"'\1'\2=>\3'$DB'\", c)
c = re.sub(r\"'username'(\s*)=>(\s*)'[^']*'\", r\"'username'\1=>\2'$USER'\", c)
c = re.sub(r\"'password'(\s*)=>(\s*)'[^']*'\", r\"'password'\1=>\2'$PASS'\", c)
with open('$FILE', 'w') as f: f.write(c)
" 2>/dev/null ;;
        magento1)
            sed -i "s|<dbname><!\[CDATA\[[^]]*\]\]></dbname>|<dbname><![CDATA[$DB]]></dbname>|" "$FILE" 2>/dev/null
            sed -i "s|<username><!\[CDATA\[[^]]*\]\]></username>|<username><![CDATA[$USER]]></username>|" "$FILE" 2>/dev/null
            sed -i "s|<password><!\[CDATA\[[^]]*\]\]></password>|<password><![CDATA[$PASS]]></password>|" "$FILE" 2>/dev/null ;;
        laravel)
            sed -i "s|^DB_DATABASE=.*|DB_DATABASE=$DB|" "$FILE" 2>/dev/null
            sed -i "s|^DB_USERNAME=.*|DB_USERNAME=$USER|" "$FILE" 2>/dev/null
            sed -i "s|^DB_PASSWORD=.*|DB_PASSWORD=$PASS|" "$FILE" 2>/dev/null ;;
    esac
}

# Busca configs de CMS (hasta 4 niveles - soporta blog/, tienda/, etc.)
# y los empareja con su DB por el nombre que YA tienen configurado
process_domain_configs() {
    local WEBROOT="$1"
    [[ -d "$WEBROOT" ]] || return 0

    # Lista de "patron_fichero:tipo" a buscar
    local FOUND_CONFIG FOUND_TYPE CONFIG_DB MATCHED
    while IFS= read -r FOUND_CONFIG; do
        [[ -z "$FOUND_CONFIG" ]] && continue
        FOUND_TYPE=""
        case "$FOUND_CONFIG" in
            */wp-config.php) FOUND_TYPE="wordpress" ;;
            */config/settings.inc.php) FOUND_TYPE="ps16" ;;
            */app/config/parameters.php) FOUND_TYPE="ps17" ;;
            */sites/default/settings.php) FOUND_TYPE="drupal" ;;
            */app/etc/env.php) FOUND_TYPE="magento2" ;;
            */app/etc/local.xml) FOUND_TYPE="magento1" ;;
            */application/config/database.php) FOUND_TYPE="codeigniter" ;;
            */configuration.php)
                if grep -q '\$db_host' "$FOUND_CONFIG" 2>/dev/null; then
                    FOUND_TYPE="whmcs"
                elif grep -q 'public \$db' "$FOUND_CONFIG" 2>/dev/null; then
                    FOUND_TYPE="joomla"
                fi ;;
            */config.php)
                if grep -q 'CFG->dbname' "$FOUND_CONFIG" 2>/dev/null; then
                    FOUND_TYPE="moodle"
                elif grep -q "DB_DATABASE" "$FOUND_CONFIG" 2>/dev/null; then
                    FOUND_TYPE="opencart"
                fi ;;
            */.env)
                grep -q "^DB_DATABASE=" "$FOUND_CONFIG" 2>/dev/null && FOUND_TYPE="laravel" ;;
        esac
        [[ -z "$FOUND_TYPE" ]] && continue

        CONFIG_DB=$(get_config_dbname "$FOUND_CONFIG" "$FOUND_TYPE")
        [[ -z "$CONFIG_DB" ]] && continue
        info "CMS detectado ($FOUND_TYPE): $FOUND_CONFIG [DB configurada: $CONFIG_DB]"

        # Buscar la DB migrada cuyo nombre coincida con la configurada
        MATCHED=""
        for DB_ENTRY in "${DB_CREATED[@]:-}"; do
            DB_FINAL=$(echo "$DB_ENTRY" | cut -d: -f1)
            DB_USER=$(echo "$DB_ENTRY" | cut -d: -f2)
            DB_PASS=$(echo "$DB_ENTRY" | cut -d: -f3-)
            if [[ "$DB_FINAL" == "$CONFIG_DB" ]]; then
                update_one_config "$FOUND_CONFIG" "$FOUND_TYPE" "$DB_FINAL" "$DB_USER" "$DB_PASS"
                log "  Config actualizado con DB $DB_FINAL (match exacto)"
                MATCHED="yes"
                break
            fi
        done

        # Sin match exacto: si solo hay 1 DB migrada, usarla como fallback
        if [[ -z "$MATCHED" ]]; then
            if [[ ${#DB_CREATED[@]} -eq 1 ]]; then
                DB_ENTRY="${DB_CREATED[0]}"
                DB_FINAL=$(echo "$DB_ENTRY" | cut -d: -f1)
                DB_USER=$(echo "$DB_ENTRY" | cut -d: -f2)
                DB_PASS=$(echo "$DB_ENTRY" | cut -d: -f3-)
                update_one_config "$FOUND_CONFIG" "$FOUND_TYPE" "$DB_FINAL" "$DB_USER" "$DB_PASS"
                log "  Config actualizado con DB $DB_FINAL (unica DB migrada)"
            else
                warn "  Sin DB coincidente para $CONFIG_DB - revisar manualmente"
                echo "CMS sin match: $FOUND_CONFIG (esperaba DB: $CONFIG_DB)" >> "$CREDS_FILE"
            fi
        fi
    done < <(find "$WEBROOT" -maxdepth 4 \
        \( -name "wp-config.php" -o -name "settings.inc.php" -o -name "parameters.php" \
           -o -name "configuration.php" -o -name "config.php" -o -name "settings.php" \
           -o -name "env.php" -o -name "local.xml" -o -name "database.php" -o -name ".env" \) \
        -type f 2>/dev/null)
}

if [[ ${#DB_CREATED[@]} -gt 0 ]]; then
    log "DBs migradas en esta ejecucion: ${#DB_CREATED[@]}"
    # Procesar TODOS los dominios: principal, addons Y subdominios.
    # Un subdominio puede tener su propio CMS (blog.dominio.com, tienda...).
    [[ -n "$MAIN_DOMAIN" ]] && \
        process_domain_configs "/home/$CPANEL_USER/web/$MAIN_DOMAIN/public_html"
    for ADDON in "${ADDON_DOMAINS[@]:-}"; do
        [[ -n "$ADDON" ]] && \
            process_domain_configs "/home/$CPANEL_USER/web/$ADDON/public_html"
    done
    for SUB in "${SUB_DOMAINS[@]:-}"; do
        [[ -n "$SUB" ]] && \
            process_domain_configs "/home/$CPANEL_USER/web/$SUB/public_html"
    done
else
    warn "No hay DBs migradas en esta ejecucion - saltando actualizacion de CMS"
fi

# -- Reconstruir configuracion de usuario -----------------------
header "Reconstruyendo configuracion"

ALL_DOMAINS=()
[[ -n "$MAIN_DOMAIN" ]] && ALL_DOMAINS+=("$MAIN_DOMAIN")
# Anadir addons y subdominios (protegido para arrays vacios con set -u)
for d in "${ADDON_DOMAINS[@]:-}"; do [[ -n "$d" ]] && ALL_DOMAINS+=("$d"); done
for d in "${SUB_DOMAINS[@]:-}"; do [[ -n "$d" ]] && ALL_DOMAINS+=("$d"); done

# Reconstruir configuracion del usuario para aplicar todos los cambios
$BIN/v-rebuild-user "$CPANEL_USER" 2>/dev/null && log "Configuracion reconstruida" || true

# SSL: NO se emite automaticamente durante la migracion.
# Motivo: al migrar, el DNS del dominio suele seguir apuntando al servidor
# de origen, por lo que la validacion de Let's Encrypt falla y cada intento
# fallido cuenta para el limite de la API (5 fallos/hora por dominio).
# Se listan los comandos para ejecutarlos cuando el DNS ya apunte aqui.
header "SSL (emision manual)"
if [[ ${#ALL_DOMAINS[@]} -gt 0 ]]; then
    warn "El SSL NO se emite automaticamente (el DNS aun puede apuntar al origen)."
    warn "Cuando el DNS apunte a este servidor, ejecuta:"
    echo ""
    for DOMAIN in "${ALL_DOMAINS[@]:-}"; do
        [[ -z "$DOMAIN" ]] && continue
        echo "  $BIN/v-add-letsencrypt-domain $CPANEL_USER $DOMAIN www.$DOMAIN yes"
    done
    echo ""
    log "${#ALL_DOMAINS[@]} dominios pendientes de SSL (ver comandos arriba)"
fi

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
