; origin-src: deb/php-fpm/multiphp.tpl
;#=========================================================================#
;# Default Web Domain Template - QemuCP Optimized                          #
;# DO NOT MODIFY THIS FILE! CHANGES WILL BE LOST WHEN REBUILDING DOMAINS   #
;#=========================================================================#

[%domain%]
listen = /run/php/php%backend_version%-fpm-%domain%.sock
listen.owner = %user%
listen.group = www-data
listen.mode = 0660

user = %user%
group = %user%

pm = ondemand
pm.max_children = 16
pm.max_requests = 500
pm.process_idle_timeout = 10s
pm.status_path = /status

; Request timeouts
request_terminate_timeout = 300
request_slowlog_timeout = 10s
slowlog = /var/log/php%backend_version%-fpm-slow.log

php_admin_value[upload_tmp_dir] = /home/%user%/tmp
; Session backend: Redis (QemuCP) - fallback a ficheros si Redis no disponible
php_admin_value[session.save_handler] = redis
php_admin_value[session.save_path] = "tcp://127.0.0.1:6379?timeout=1&prefix=SESS_&database=1"
php_admin_value[open_basedir] = /home/%user%/.composer:/home/%user%/web/%domain%/public_html:/home/%user%/web/%domain%/private:/home/%user%/web/%domain%/public_shtml:/home/%user%/tmp:/tmp:/var/www/html:/bin:/usr/bin:/usr/local/bin:/usr/share:/opt
php_admin_value[sendmail_path] = /usr/sbin/sendmail -t -i -f admin@%domain%

env[PATH] = /usr/local/bin:/usr/bin:/bin
env[TMP] = /home/%user%/tmp
env[TMPDIR] = /home/%user%/tmp

; QemuCP Performance Optimizations
php_admin_value[memory_limit] = 512M
php_admin_value[upload_max_filesize] = 256M
php_admin_value[post_max_size] = 256M
php_admin_value[max_file_uploads] = 100
php_admin_value[max_execution_time] = 300
php_admin_value[max_input_time] = 300
php_admin_value[max_input_vars] = 10000
php_flag[display_errors] = off
php_admin_flag[log_errors] = on

; OPcache
php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 256
php_admin_value[opcache.interned_strings_buffer] = 32
php_admin_value[opcache.max_accelerated_files] = 30000
php_admin_value[opcache.validate_timestamps] = 1
php_admin_value[opcache.revalidate_freq] = 60
php_admin_value[opcache.save_comments] = 1

; Sessions
php_admin_value[session.gc_maxlifetime] = 1440
php_admin_value[session.cookie_httponly] = 1
php_admin_value[session.cookie_secure] = 1
php_admin_value[session.use_strict_mode] = 1

; SOAP (PrestaShop)
php_value[soap.wsdl_cache_enabled] = 1
php_value[soap.wsdl_cache_ttl] = 86400
env[TEMP] = /home/%user%/tmp
