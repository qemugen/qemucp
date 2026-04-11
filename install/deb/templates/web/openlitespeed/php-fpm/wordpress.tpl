#=========================================================================#
# WordPress OpenLiteSpeed Template - QemuCP                               #
# Incluye LSCache, proteccion xmlrpc y reglas WordPress                   #
#=========================================================================#

virtualHost %domain% {
  vhRoot                  %docroot%
  configFile              $SERVER_ROOT/conf/vhosts/%domain%/wordpress.conf
  allowSymbolLink         1
  enableScript            1
  restrained              0
  setUIDMode              2
}
