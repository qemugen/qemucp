#=========================================================================#
# Default OpenLiteSpeed Web Domain Template - QemuCP                      #
# DO NOT MODIFY THIS FILE! CHANGES WILL BE LOST WHEN REBUILDING DOMAINS   #
#=========================================================================#

virtualHost %domain% {
  vhRoot                  %docroot%
  configFile              $SERVER_ROOT/conf/vhosts/%domain%/vhconf.conf
  allowSymbolLink         1
  enableScript            1
  restrained              0
  setUIDMode              2
}
