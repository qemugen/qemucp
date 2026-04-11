#!/bin/bash
# QemuCP - Instalar WP-CLI globalmente
# Se ejecuta automaticamente durante la instalacion de QemuCP

log() { echo "[OK] $1"; }

if command -v wp &>/dev/null; then
    log "WP-CLI ya instalado: $(wp --version 2>/dev/null)"
    exit 0
fi

log "Instalando WP-CLI..."
curl -sS https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
    -o /usr/local/bin/wp 2>/dev/null || \
    wget -q https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar \
        -O /usr/local/bin/wp

chmod +x /usr/local/bin/wp

if wp --version &>/dev/null; then
    log "WP-CLI instalado: $(wp --version)"
else
    echo "[!] WP-CLI no se pudo instalar - WordPress se instalara via wget"
fi
