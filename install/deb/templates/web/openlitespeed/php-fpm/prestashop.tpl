#=========================================================================#
# PrestaShop OpenLiteSpeed Template - QemuCP                              #
#=========================================================================#

virtualHost %domain% {
  vhRoot                  %docroot%
  configFile              $SERVER_ROOT/conf/vhosts/%domain%/prestashop.conf
  allowSymbolLink         1
  enableScript            1
  restrained              0
  setUIDMode              2
}
