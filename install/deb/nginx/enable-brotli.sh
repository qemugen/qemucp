#!/bin/bash
# QemuCP - Activar Brotli en Nginx (ejecutar tras compilar ngx_brotli)
NGINX_CONF="/etc/nginx/nginx.conf"

# Descomentar directivas brotli
sed -i 's/\t# brotli /\tbrotli /g' "$NGINX_CONF"
sed -i 's/\t# brotli_/\tbrotli_/g' "$NGINX_CONF"

# Verificar y reiniciar
nginx -t && systemctl reload nginx && echo "Brotli activado"
