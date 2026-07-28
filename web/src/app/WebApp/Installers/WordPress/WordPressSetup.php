<?php
// QemuCP - WordPress Optimized Installer
// Basado en el instalador original de HestiaCP con mejoras:
// - WP-CLI para instalacion limpia
// - Configuracion wp-config.php optimizada
// - Prefijo de tabla personalizado
// - Salts de seguridad generados
// - Desactivacion de edicion de ficheros desde panel WP
// - Configuracion de Redis object cache

namespace Hestia\WebApp\Installers\WordPress;

use Hestia\WebApp\Installers\BaseSetup;

class WordPressSetup extends BaseSetup {

	protected $config = [
		"form" => [
			"site_name" => ["type" => "text", "value" => "WordPress Blog"],
			"username" => ["value" => "wpadmin"],
			"email" => "text",
			"password" => "password",
			"install_directory" => ["type" => "text", "value" => "/", "placeholder" => "/"],
			"language" => [
				"type" => "select",
				"value" => "en_US",
				"options" => [
					"cs_CZ" => "Czech",
					"de_DE" => "German",
					"es_ES" => "Spanish",
					"en_US" => "English",
					"fr_FR" => "French",
					"hu_HU" => "Hungarian",
					"it_IT" => "Italian",
					"ja" => "Japanese",
					"nl_NL" => "Dutch",
					"pt_PT" => "Portuguese",
					"pt_BR" => "Portuguese (Brazil)",
					"sk_SK" => "Slovak",
					"sr_RS" => "Serbian",
					"sv_SE" => "Swedish",
					"tr_TR" => "Turkish",
					"ru_RU" => "Russian",
					"uk" => "Ukrainian",
					"zh-CN" => "Simplified Chinese (China)",
					"zh_TW" => "Traditional Chinese",
				],
			],
		],
		"database" => true,
		"resources" => [
			"wp" => ["src" => "https://wordpress.org/latest.tar.gz"],
		],
		"server" => [
			"nginx" => [
				"template" => "wordpress",
			],
			"php" => [
				"supported" => ["7.4", "8.0", "8.1", "8.2", "8.3", "8.4", "8.5"],
			],
		],
	];

    public function install(array $options = []): bool {
        // 1. Descargar WordPress via WP-CLI si esta disponible, sino wget
        if ($this->hasWpCli()) {
            return $this->installViaWpCli($options);
        }
        return $this->installViaWget($options);
    }

    private function hasWpCli(): bool {
        exec('which wp 2>/dev/null', $out, $rc);
        return $rc === 0;
    }

    private function installViaWpCli(array $options): bool {
        $docroot  = $this->getDocRoot();
        $domain   = $options['domain'] ?? '';
        $user     = $options['user'] ?? 'admin';
        $pass     = $options['password'] ?? bin2hex(random_bytes(8));
        $email    = $options['email'] ?? 'admin@' . $domain;
        $title    = $options['site_title'] ?? 'My WordPress Site';
        $dbname   = $options['database_name'] ?? '';
        $dbuser   = $options['database_user'] ?? '';
        $dbpass   = $options['database_password'] ?? '';
        $prefix   = 'wp_' . substr(md5(rand()), 0, 4) . '_';

        // Descargar WP
        exec("wp core download --path={$docroot} --locale=es_ES 2>/dev/null", $out, $rc);
        if ($rc !== 0) {
            exec("wp core download --path={$docroot} 2>/dev/null", $out, $rc);
        }

        // Crear wp-config con prefijo aleatorio y optimizaciones
        $db_host = defined('DB_HOST') ? DB_HOST : 'localhost';
        exec("wp config create --path={$docroot} --dbname={$dbname} --dbuser={$dbuser} --dbpass={$dbpass} --dbhost={$db_host} --dbprefix={$prefix} 2>/dev/null");

		$this->appcontext->runUser("v-list-web-domain", [$this->domain, "json"], $status);

        // Post-instalacion
        if ($rc === 0) {
            $this->postInstall($docroot, $options);
        }

        return $rc === 0;
    }

    private function installViaWget(array $options): bool {
        $docroot = $this->getDocRoot();
        exec("wget -q https://wordpress.org/latest.tar.gz -O /tmp/wp.tar.gz && tar -xzf /tmp/wp.tar.gz -C /tmp && cp -r /tmp/wordpress/* {$docroot}/ && rm -rf /tmp/wp.tar.gz /tmp/wordpress");
        $this->applyWpConfigOptimizations($docroot);
        return true;
    }

    private function applyWpConfigOptimizations(string $docroot): void {
        $config = $docroot . '/wp-config.php';
        if (!file_exists($config)) return;

        $additions = "\n" . implode("\n", [
            "// QemuCP Security & Performance",
            "define('DISALLOW_FILE_EDIT', true);",           // Sin editor de ficheros en el panel WP
            "define('DISALLOW_FILE_MODS', false);",           // Permite instalar plugins
            "define('WP_POST_REVISIONS', 5);",               // Max 5 revisiones por post
            "define('AUTOSAVE_INTERVAL', 120);",             // Autosave cada 2 min
            "define('EMPTY_TRASH_DAYS', 7);",                // Papelera 7 dias
            "define('WP_MEMORY_LIMIT', '256M');",            // Memoria PHP para WP
            "define('WP_MAX_MEMORY_LIMIT', '512M');",        // Memoria admin
            "define('COMPRESS_CSS', true);",                 // Comprimir CSS
            "define('COMPRESS_SCRIPTS', true);",             // Comprimir JS
            "define('CONCATENATE_SCRIPTS', false);",         // No concatenar (mejor con cache)
            "define('FORCE_SSL_ADMIN', true);",              // Admin siempre HTTPS
            "define('WP_CACHE', true);",                     // Habilitar cache
            "",
            "// QemuCP Redis Object Cache",
            "define('WP_REDIS_HOST', '127.0.0.1');",
            "define('WP_REDIS_PORT', 6379);",
            "define('WP_REDIS_DATABASE', 2);",              // DB 2 para objetos WP (1 para sesiones)
            "define('WP_REDIS_TIMEOUT', 1);",
            "define('WP_REDIS_READ_TIMEOUT', 1);",
        ]);

        // Insertar antes del comentario de fin de edicion
        $content = file_get_contents($config);
        $content = str_replace(
            "/* That's all, stop editing!",
            $additions . "\n\n/* That's all, stop editing!",
            $content
        );
        file_put_contents($config, $content);
    }

    private function postInstall(string $docroot, array $options): void {
        // Eliminar plugins de ejemplo
        exec("wp plugin delete hello akismet --path={$docroot} 2>/dev/null");

        // Instalar Redis Object Cache si WP-CLI disponible
        exec("wp plugin install redis-cache --activate --path={$docroot} 2>/dev/null");
        exec("wp redis enable --path={$docroot} 2>/dev/null");

        // Configurar permalinks SEO
        exec("wp rewrite structure '/%postname%/' --path={$docroot} 2>/dev/null");
        exec("wp rewrite flush --path={$docroot} 2>/dev/null");

        // Eliminar posts/paginas de ejemplo
        exec("wp post delete 1 2 --force --path={$docroot} 2>/dev/null");

        // Timezone
        exec("wp option update timezone_string 'Europe/Madrid' --path={$docroot} 2>/dev/null");

        // Deshabilitar comentarios por defecto
        exec("wp option update default_comment_status closed --path={$docroot} 2>/dev/null");

        // Configurar uploads
        exec("wp option update uploads_use_yearmonth_folders 1 --path={$docroot} 2>/dev/null");
    }

    private function getDocRoot(): string {
        return $this->appcontext->getDocumentRoot() ?? '/var/www/html';
    }
}
