#!/bin/bash
# ============================================================================
#  QemuCP - Parches de seguridad de PHP (todas las versiones instaladas)
#
#  Uso:
#    bash parche-php.sh                      actualiza PHP y reinicia
#    bash parche-php.sh --comprobar          solo informa, no cambia nada
#    bash parche-php.sh --mitigar            ademas, mitigacion provisional
#    bash parche-php.sh --quitar-mitigacion  quita la mitigacion y reinicia
#
#  Motivo (21-oct-2026, "php2shell"): CVE-2026-109618 y CVE-2026-109619,
#  ejecucion remota de codigo en PHP desde la 5.4 hasta la 8.5, ya atacadas.
#  Versiones corregidas: 8.5.12, 8.4.27, 8.3.36 y 8.2.35. PHP 8.1 y anteriores
#  NO tienen version oficial corregida; el repositorio de Ondrej Sury (el que
#  usa QemuCP) publico el parche incorporado para 7.2-8.1 (CORREGIDA_PKG).
#
#  Lo que hace:
#   1. apt update y actualiza TODOS los paquetes php de cada version instalada
#      (repositorio de Ondrej Sury; conserva php.ini y los pools: confold).
#   2. SOLO con --mitigar: /etc/php/X.Y/fpm/conf.d/99-qemucp-seguridad.ini
#        session.upload_progress.enabled = 0   (CVE-2026-109619)
#        fatal_error_backtraces = 0            (solo 8.5)
#      Es lo que recomienda PHP mientras no se parchea. No sustituye al parche.
#      Desactiva la barra de progreso de subidas de PHP en TODAS las webs del
#      servidor: no se aplica por defecto (puede haber clientes que la usen).
#   3. Actualizaciones automaticas de seguridad tambien para PHP: Ubuntu solo
#      aplica las de su repositorio; se anade el de Ondrej a unattended-upgrades.
#   4. Reinicia todos los php-fpm (el codigo viejo sigue en memoria hasta
#      reiniciar) y Apache.
#   5. Informa de cada version: parcheada / sin parche, y de las webs que usan
#      versiones sin parche oficial (7.x, 8.0, 8.1) para pasarlas a 8.2+.
#
#  Se puede relanzar: si no hay nada nuevo, no cambia nada.
# ============================================================================
set -uo pipefail
[[ $EUID -ne 0 ]] && { echo "Ejecuta como root"; exit 1; }
MODO="${1:-actualizar}"
case "$MODO" in
    actualizar|--comprobar|--mitigar|--quitar-mitigacion) ;;
    *) echo "Uso: bash $0 [--comprobar | --mitigar | --quitar-mitigacion]"; exit 1 ;;
esac
LOG=/var/log/qemucp-parche-php.log
HESTIA=/usr/local/hestia
CVES='CVE-2026-10961[89]'

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; N='\033[0m'
ok()   { echo -e "${G}[OK]${N} $*"; }
avi()  { echo -e "${Y}[!!]${N} $*"; }
mal()  { echo -e "${R}[XX]${N} $*"; }

# Version corregida minima por rama (vacio = sin version oficial)
declare -A CORREGIDA=([8.2]=8.2.35 [8.3]=8.3.36 [8.4]=8.4.27 [8.5]=8.5.12)
# Ramas sin soporte: el repositorio de Ondrej Sury publico el 21/22-oct-2026
# el parche incorporado (mismo numero de PHP, revision del paquete mayor).
# Version completa minima del paquete (dpkg --compare-versions).
declare -A CORREGIDA_PKG=([7.2]=7.2.34-66 [7.3]=7.3.33-35 [7.4]=1:7.4.33-31 [8.0]=1:8.0.30-25 [8.1]=8.1.34-9)

VERSIONES=()
for d in /etc/php/*/; do
    v=$(basename "$d")
    [[ "$v" =~ ^[0-9]+\.[0-9]+$ ]] || continue
    dpkg -l "php$v-fpm" 2>/dev/null | grep -q '^ii' || dpkg -l "php$v-cli" 2>/dev/null | grep -q '^ii' || continue
    VERSIONES+=("$v")
done
[[ ${#VERSIONES[@]} -eq 0 ]] && { echo "No hay PHP instalado"; exit 0; }

# Version "upstream" de un paquete: 8.3.36-1+ubuntu24.04.1+deb.sury.org+1 -> 8.3.36
ver_paquete() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null | sed -E 's/^[0-9]+://; s/[-+~].*$//'; }

# 0 = parcheada, 1 = no
parcheada() {
    local v="$1" inst
    inst=$(ver_paquete "php$v-common")
    [[ -z "$inst" ]] && inst=$(ver_paquete "php$v-fpm")
    if [[ -n "${CORREGIDA[$v]:-}" ]]; then
        dpkg --compare-versions "$inst" ge "${CORREGIDA[$v]}" && return 0
    fi
    if [[ -n "${CORREGIDA_PKG[$v]:-}" ]]; then
        local full
        full=$(dpkg-query -W -f='${Version}' "php$v-common" 2>/dev/null)
        [[ -n "$full" ]] && dpkg --compare-versions "$full" ge "${CORREGIDA_PKG[$v]}" && return 0
    fi
    # Ramas sin version oficial (o Ubuntu con el numero viejo): buscar el CVE
    # en el registro de cambios del paquete (backports de Sury / Ubuntu)
    local c
    for c in /usr/share/doc/php$v-common/changelog.Debian.gz /usr/share/doc/php$v-fpm/changelog.Debian.gz; do
        [[ -f "$c" ]] && zgrep -qE "$CVES" "$c" 2>/dev/null && return 0
    done
    return 1
}

informe() {
    echo ""
    echo "=== Estado de PHP ==="
    local v inst SIN=()
    for v in "${VERSIONES[@]}"; do
        inst=$(dpkg-query -W -f='${Version}' "php$v-fpm" 2>/dev/null || dpkg-query -W -f='${Version}' "php$v-cli" 2>/dev/null)
        if parcheada "$v"; then
            ok "PHP $v  parcheado        ($inst)"
        else
            SIN+=("$v")
            if [[ -n "${CORREGIDA[$v]:-}" ]]; then
                mal "PHP $v  SIN PARCHE       ($inst; hace falta ${CORREGIDA[$v]} o posterior)"
            else
                mal "PHP $v  SIN PARCHE       ($inst; rama sin soporte; hace falta ${CORREGIDA_PKG[$v]:-el backport} o posterior)"
            fi
        fi
        if [[ -f "/etc/php/$v/fpm/conf.d/99-qemucp-seguridad.ini" ]]; then
            echo "         mitigacion activa (session.upload_progress desactivado)"
        fi
    done
    # Webs en versiones sin parche
    if [[ ${#SIN[@]} -gt 0 && -d $HESTIA/data/users ]]; then
        echo ""
        echo "=== Webs que usan una version SIN PARCHE ==="
        local patron f u
        patron=$(printf 'PHP-%s|' "${SIN[@]//./_}"); patron="${patron%|}"
        for f in $HESTIA/data/users/*/web.conf; do
            u=$(basename "$(dirname "$f")")
            grep -oP "DOMAIN='[^']+'.*?BACKEND='(${patron})'" "$f" 2>/dev/null \
                | sed -E "s/DOMAIN='([^']+)'.*BACKEND='([^']+)'/  \1 ($u, \2)/"
        done | sort | tee /root/webs-php-sin-parche.txt
        echo "Lista en /root/webs-php-sin-parche.txt. Pasalas a PHP 8.2 o superior cuando la web lo admita:"
        echo "  v-change-web-domain-backend-tpl USUARIO DOMINIO PHP-8_3"
    fi
}

if [[ "$MODO" == "--comprobar" ]]; then
    informe
    exit 0
fi

reiniciar_php() {
    local v
    for v in "${VERSIONES[@]}"; do
        systemctl list-unit-files "php$v-fpm.service" >/dev/null 2>&1 || continue
        if php-fpm$v -t >> "$LOG" 2>&1; then
            systemctl restart "php$v-fpm" >> "$LOG" 2>&1 || mal "php$v-fpm no arranca (ver journalctl -u php$v-fpm)"
        else
            mal "php$v-fpm: la configuracion no valida (ver $LOG); no se reinicia"
        fi
    done
    if systemctl is-active --quiet apache2 2>/dev/null; then
        apache2ctl configtest >> "$LOG" 2>&1 && systemctl reload apache2 >> "$LOG" 2>&1
    fi
    ok "php-fpm y Apache reiniciados"
}

if [[ "$MODO" == "--quitar-mitigacion" ]]; then
    : > "$LOG"
    rm -f /etc/php/*/fpm/conf.d/99-qemucp-seguridad.ini
    ok "Mitigacion quitada: session.upload_progress vuelve a su valor normal"
    reiniciar_php
    exit 0
fi

: > "$LOG"
echo "Versiones instaladas: ${VERSIONES[*]}"

# --- 1. Actualizar paquetes ------------------------------------------------
# Repositorio de Ondrej (el que usa QemuCP). Si faltara, se anade.
if ! grep -rqs "ondrej/php\|packages.sury.org/php" /etc/apt/sources.list /etc/apt/sources.list.d/; then
    avi "No esta el repositorio de PHP de Ondrej Sury: se anade"
    add-apt-repository -y ppa:ondrej/php >> "$LOG" 2>&1 || avi "No se pudo anadir ppa:ondrej/php (ver $LOG)"
fi
echo "Actualizando la lista de paquetes..."
apt-get update >> "$LOG" 2>&1 || avi "apt-get update dio errores (ver $LOG)"
export DEBIAN_FRONTEND=noninteractive
for v in "${VERSIONES[@]}"; do
    PKGS=$(dpkg -l "php$v*" 2>/dev/null | awk '/^ii/ {print $2}' | tr '\n' ' ')
    [[ -z "$PKGS" ]] && continue
    ANTES=$(dpkg-query -W -f='${Version}' "php$v-common" 2>/dev/null)
    # shellcheck disable=SC2086
    if apt-get install --only-upgrade -y -o Dpkg::Options::="--force-confold" $PKGS >> "$LOG" 2>&1; then
        DESPUES=$(dpkg-query -W -f='${Version}' "php$v-common" 2>/dev/null)
        if [[ "$ANTES" != "$DESPUES" ]]; then ok "PHP $v actualizado: $ANTES -> $DESPUES"
        else echo "     PHP $v: sin version nueva en el repositorio ($ANTES)"; fi
    else
        mal "PHP $v: fallo al actualizar (ver $LOG)"
    fi
done

# --- 2. Mitigacion (solo con --mitigar) --------------------------------------
[[ "$MODO" == "--mitigar" ]] && for v in "${VERSIONES[@]}"; do
    [[ -d "/etc/php/$v/fpm/conf.d" ]] || continue
    INI="/etc/php/$v/fpm/conf.d/99-qemucp-seguridad.ini"
    {
        echo "; QemuCP: mitigacion php2shell (CVE-2026-109618 / CVE-2026-109619)"
        echo "; Recomendada por PHP ademas del parche. Ver install/parche-php.sh"
        echo "session.upload_progress.enabled = 0"
        [[ "$v" == 8.5 ]] && echo "fatal_error_backtraces = 0"
    } > "$INI.nuevo"
    if cmp -s "$INI.nuevo" "$INI"; then rm -f "$INI.nuevo"; else mv -f "$INI.nuevo" "$INI"; fi
done
if [[ "$MODO" == "--mitigar" ]]; then
    ok "Mitigacion aplicada en todos los php-fpm (99-qemucp-seguridad.ini)"
elif ls /etc/php/*/fpm/conf.d/99-qemucp-seguridad.ini >/dev/null 2>&1; then
    echo "     Mitigacion: se mantiene la que ya habia (quitar: --quitar-mitigacion)"
fi

# --- 3. Actualizaciones automaticas de PHP ------------------------------------
if dpkg -l unattended-upgrades 2>/dev/null | grep -q '^ii'; then
    cat > /etc/apt/apt.conf.d/52qemucp-php-seguridad << 'EOF'
// QemuCP: aplicar tambien las actualizaciones de PHP del repositorio de
// Ondrej Sury (Ubuntu solo aplica las de su propio repositorio).
Unattended-Upgrade::Allowed-Origins {
    "LP-PPA-ondrej-php:${distro_codename}";
};
Unattended-Upgrade::Package-Blacklist {
    "hestia";
};
EOF
    ok "Actualizaciones automaticas de PHP activadas (unattended-upgrades)"
else
    avi "unattended-upgrades no esta instalado: las proximas actualizaciones de PHP hay que lanzarlas con este script"
fi

# --- 4. Reiniciar ------------------------------------------------------------
reiniciar_php

# Comprobacion: los procesos en marcha cargan la mitigacion
for v in "${VERSIONES[@]}"; do
    [[ -f "/etc/php/$v/fpm/conf.d/99-qemucp-seguridad.ini" ]] || continue
    php-fpm$v -i 2>&1 | grep -qi "session.upload_progress.enabled => off" \
        || avi "PHP $v: la mitigacion no aparece en php-fpm$v -i"
done

informe
