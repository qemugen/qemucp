#!/bin/bash
user=$1; domain=$2; ip=$3; home=$4; docroot=$5
OLS_CONF="/usr/local/lsws/conf/vhosts/$domain"
mkdir -p "$OLS_CONF"

cat > "$OLS_CONF/prestashop.conf" << VHCONF
docRoot                   $docroot
vhDomain                  $domain
vhAliases                 www.$domain
enableGzip                1
enableBr                  1

index {
  indexFiles              index.php, index.html
  autoIndex               0
}

rewrite {
  enable                  1
  autoLoadHtaccess        1
}

# Proteger directorios admin y config
context /config {
  allowBrowse             0
}
context /app/config {
  allowBrowse             0
}
context /app/Resources {
  allowBrowse             0
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
  autoStart               2
  path                    /usr/local/lsws/lsphp83/bin/lsphp
  memSoftLimit            2047M
  memHardLimit            2047M
}

module cache {
  ls_enabled              1
  publicCache             1
  privateCache            1
  maxCacheObjSize         10000000
  storagePath             /dev/shm/lscache/%domain%
}
VHCONF

mkdir -p /dev/shm/lscache/$domain
/usr/local/lsws/bin/lswsctrl restart > /dev/null 2>&1 || true
