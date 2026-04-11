#!/bin/bash
user=$1; domain=$2; ip=$3; home=$4; docroot=$5
OLS_CONF="/usr/local/lsws/conf/vhosts/$domain"
mkdir -p "$OLS_CONF"

cat > "$OLS_CONF/wordpress.conf" << VHCONF
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
  rules                   <<<END_RULES
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
  END_RULES
}

# Bloquear xmlrpc
context /xmlrpc.php {
  allowBrowse             0
  rewrite {
    rules                 <<<END_RULES
RewriteRule .* - [F,L]
    END_RULES
  }
}

# Proteger wp-login con rate limiting
context /wp-login.php {
  rewrite {
    rules                 <<<END_RULES
RewriteRule .* - [E=THROTTLE_BPS:1M]
    END_RULES
  }
}

scripthandler {
  add                     lsapi:lsphp83 php
}

module cache {
  ls_enabled              1
  publicCache             1
  privateCache            1
  maxCacheObjSize         10000000
  maxStaleAge             200
  storagePath             /dev/shm/lscache/%domain%
  ls_enabled              1
}
VHCONF

mkdir -p /dev/shm/lscache/$domain
/usr/local/lsws/bin/lswsctrl restart > /dev/null 2>&1 || true
