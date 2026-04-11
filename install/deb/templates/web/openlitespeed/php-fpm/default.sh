#!/bin/bash
# QemuCP - Script de configuracion de vhost OpenLiteSpeed
# Se ejecuta al crear/modificar un dominio con motor OLS

user=$1
domain=$2
ip=$3
home=$4
docroot=$5

OLS_CONF="/usr/local/lsws/conf/vhosts/$domain"
mkdir -p "$OLS_CONF"

cat > "$OLS_CONF/vhconf.conf" << VHCONF
docRoot                   $docroot
vhDomain                  $domain
vhAliases                 www.$domain
adminEmails               admin@$domain
enableGzip                1
enableBr                  1

index  {
  useServer               0
  indexFiles              index.php, index.html, index.htm
  autoIndex               0
}

errorpage 404 {
  url                     /error/404.html
}

errorpage 500 {
  url                     /error/500.html
}

expires {
  enableExpires           1
  expiresByType           image/gif=A604800, image/jpeg=A604800, image/png=A604800, image/webp=A604800
  expiresByType           text/css=A604800, application/javascript=A604800
  expiresByType           font/ttf=A604800, font/woff=A604800, font/woff2=A604800
}

rewrite  {
  enable                  1
  autoLoadHtaccess        1
}

context / {
  type                    NULL
  location                $docroot
  allowBrowse             1

  rewrite  {
    enable                1
  }

  addDefaultCharset       off

  phpIniOverride  {
    php_admin_value open_basedir $docroot:$home/$user/tmp
    php_admin_value upload_tmp_dir $home/$user/tmp
    php_admin_value session.save_path $home/$user/tmp
  }
}

scripthandler {
  add                     lsapi:lsphp83 php
}

extprocessor lsphp83 {
  type                    lsapi
  address                 uds://tmp/lshttpd/lsphp83.sock
  maxConns                35
  env                     PHP_LSAPI_CHILDREN=35
  initTimeout             60
  retryTimeout            0
  persistConn             1
  respBuffer              0
  autoStart               2
  path                    /usr/local/lsws/lsphp83/bin/lsphp
  backlog                 100
  instances               1
  priority                0
  memSoftLimit            2047M
  memHardLimit            2047M
  procSoftLimit           1400
  procHardLimit           1500
}

vhssl  {
  keyFile                 $home/$user/conf/web/$domain/ssl/$domain.key
  certFile                $home/$user/conf/web/$domain/ssl/$domain.crt
  certChain               1
  sslProtocol             24
  enableECDHE             1
  renegProtection         1
  sslSessionCache         1
  enableSpdy              15
  enableQuic              1
}

# LSCache para WordPress y PrestaShop
module cache {
  ls_enabled              1
  checkPrivateCache       1
  checkPublicCache        1
  maxCacheObjSize         10000000
  maxStaleAge             200
  qsCache                 1
  reqCookieCache          1
  ignoreReqCacheCtrl      1
  ignoreRespCacheCtrl     0

  enablePrivateCache      1
  privateAge              60

  ls_enabled              1
}
VHCONF

# Reiniciar OLS para aplicar cambios
/usr/local/lsws/bin/lswsctrl restart > /dev/null 2>&1 || true

echo "OLS vhost $domain configurado"
