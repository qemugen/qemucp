<?php
/**
 * QemuCP - WordPress Optimizado
 * Instalador WordPress con WP-CLI, Redis, seguridad y rendimiento
 */

namespace Hestia\WebApp\Installers\WordPressOptimized;

use Hestia\WebApp\Installers\BaseSetup as BaseSetup;
use function Hestiacp\quoteshellarg\quoteshellarg;

class WordPressOptimizedSetup extends BaseSetup {

    protected $appInfo = [
        "name"      => "WordPress Optimizado (QemuCP)",
        "group"     => "cms",
        "enabled"   => true,
        "version"   => "latest",
        "thumbnail" => "wp-qemucp-thumb.png",
    ];

    protected $appname = "wordpressoptimized";

    protected $config = [
        "form" => [
            "site_title" => [
                "type"        => "text",
                "value"       => "Mi sitio WordPress",
                "placeholder" => "Nombre del sitio",
            ],
            "admin_username" => [
                "type"        => "text",
                "value"       => "admin",
                "placeholder" => "Usuario administrador",
            ],
            "admin_password" => [
                "type"        => "password",
                "value"       => "",
                "placeholder" => "Contrasena administrador",
            ],
            "admin_email" => [
                "type"        => "text",
                "value"       => "",
                "placeholder" => "Email administrador",
            ],
        ],
        "database" => true,
        "resources" => [
            "wp" => [
                "src" => "https://wordpress.org/latest.tar.gz",
            ],
        ],
        "server" => [
            "nginx" => [
                "template" => "wordpress",
            ],
            "php" => [
                "supported" => ["7.4", "8.0", "8.1", "8.2", "8.3"],
            ],
        ],
    ];

    public function install(array $options = null): bool {
        $docroot = $this->getDocRoot();
        $domain  = $this->domain;

        // Datos del formulario
        $site_title = $options["site_title"] ?? "Mi sitio WordPress";
        $admin_user = $options["admin_username"] ?? "admin";
        $admin_pass = $options["admin_password"] ?? bin2hex(random_bytes(8));
        $admin_email = $options["admin_email"] ?? "admin@" . $domain;
        $db_name = $this->appcontext->user() . "_" . ($options["database_name"] ?? "wordpress");
        $db_user = $this->appcontext->user() . "_" . ($options["database_user"] ?? "wordpress");
        $db_pass = $options["database_password"] ?? bin2hex(random_bytes(8));
        $db_host = $options["database_host"] ?? "localhost";
        $prefix  = "wp_" . substr(md5(uniqid()), 0, 4) . "_";

        // Crear base de datos
        parent::install($options);
        parent::setup($options);

        // Intentar con WP-CLI primero
        exec("which wp 2>/dev/null", $out, $rc);
        $has_wpcli = ($rc === 0);

        if ($has_wpcli) {
            // Descargar WordPress
            $this->appcontext->runUser(
                "v-run-cli-cmd",
                ["wp", "core", "download",
                 "--path=" . quoteshellarg($docroot),
                 "--locale=es_ES", "--quiet"],
                $status
            );

            // Crear wp-config
            $this->appcontext->runUser(
                "v-run-cli-cmd",
                ["wp", "config", "create",
                 "--path=" . quoteshellarg($docroot),
                 "--dbname=" . quoteshellarg($db_name),
                 "--dbuser=" . quoteshellarg($db_user),
                 "--dbpass=" . quoteshellarg($db_pass),
                 "--dbhost=" . quoteshellarg($db_host),
                 "--dbprefix=" . quoteshellarg($prefix),
                 "--quiet"],
                $status
            );

            // Aplicar optimizaciones al wp-config
            $this->applyWpConfigOptimizations($docroot);

            // Instalar WordPress
            $this->appcontext->runUser(
                "v-run-cli-cmd",
                ["wp", "core", "install",
                 "--path=" . quoteshellarg($docroot),
                 "--url=https://" . quoteshellarg($domain),
                 "--title=" . quoteshellarg($site_title),
                 "--admin_user=" . quoteshellarg($admin_user),
                 "--admin_password=" . quoteshellarg($admin_pass),
                 "--admin_email=" . quoteshellarg($admin_email),
                 "--skip-email"],
                $status
            );

            if ($status->code === 0) {
                $this->postInstall($docroot);
            }
        } else {
            // Fallback: wget + configuracion manual
            exec("wget -q https://wordpress.org/latest.tar.gz -O /tmp/wp-qemucp.tar.gz 2>/dev/null");
            exec("tar -xzf /tmp/wp-qemucp.tar.gz -C /tmp 2>/dev/null");
            exec("cp -r /tmp/wordpress/. {$docroot}/ 2>/dev/null");
            exec("rm -rf /tmp/wp-qemucp.tar.gz /tmp/wordpress 2>/dev/null");
            $this->applyWpConfigOptimizations($docroot);
        }

        return true;
    }

    private function applyWpConfigOptimizations(string $docroot): void {
        $config = $docroot . "/wp-config.php";
        if (!file_exists($config)) return;

        $optimizations = "\n// QemuCP Security & Performance\n"
            . "define('DISALLOW_FILE_EDIT', true);\n"
            . "define('WP_POST_REVISIONS', 5);\n"
            . "define('AUTOSAVE_INTERVAL', 120);\n"
            . "define('EMPTY_TRASH_DAYS', 7);\n"
            . "define('WP_MEMORY_LIMIT', '256M');\n"
            . "define('WP_MAX_MEMORY_LIMIT', '512M');\n"
            . "define('COMPRESS_CSS', true);\n"
            . "define('COMPRESS_SCRIPTS', true);\n"
            . "define('CONCATENATE_SCRIPTS', false);\n"
            . "define('FORCE_SSL_ADMIN', true);\n"
            . "define('WP_CACHE', true);\n"
            . "\n// QemuCP Redis Object Cache\n"
            . "define('WP_REDIS_HOST', '127.0.0.1');\n"
            . "define('WP_REDIS_PORT', 6379);\n"
            . "define('WP_REDIS_DATABASE', 2);\n"
            . "define('WP_REDIS_TIMEOUT', 1);\n"
            . "define('WP_REDIS_READ_TIMEOUT', 1);\n";

        $content = file_get_contents($config);
        $content = str_replace(
            "/* That's all, stop editing!",
            $optimizations . "\n/* That's all, stop editing!",
            $content
        );
        file_put_contents($config, $content);
    }

    private function postInstall(string $docroot): void {
        // Eliminar plugins innecesarios
        exec("wp plugin delete hello akismet --path=" . quoteshellarg($docroot) . " 2>/dev/null");

        // Redis Object Cache
        exec("wp plugin install redis-cache --activate --path=" . quoteshellarg($docroot) . " 2>/dev/null");
        exec("wp redis enable --path=" . quoteshellarg($docroot) . " 2>/dev/null");

        // Permalinks SEO
        exec("wp rewrite structure '/%postname%/' --path=" . quoteshellarg($docroot) . " 2>/dev/null");
        exec("wp rewrite flush --path=" . quoteshellarg($docroot) . " 2>/dev/null");

        // Eliminar contenido de ejemplo
        exec("wp post delete 1 2 --force --path=" . quoteshellarg($docroot) . " 2>/dev/null");

        // Configuraciones
        exec("wp option update timezone_string 'Europe/Madrid' --path=" . quoteshellarg($docroot) . " 2>/dev/null");
        exec("wp option update default_comment_status closed --path=" . quoteshellarg($docroot) . " 2>/dev/null");
        exec("wp option update uploads_use_yearmonth_folders 1 --path=" . quoteshellarg($docroot) . " 2>/dev/null");
    }

    public function getDocRoot($append_relative_path = null): string {
        $homedir = $this->appcontext->user_home ?? "/home";
        $docroot = "/home/" . $this->appcontext->user() . "/web/" . $this->domain . "/public_html";
        return empty($append_relative_path) ? $docroot : $docroot . "/" . ltrim($append_relative_path, "/");
    }
}
