<?php
/**
 * QemuCP - PrestaShop Optimizado
 * Instalador PrestaShop con configuracion optimizada para rendimiento
 */

namespace Hestia\WebApp\Installers\PrestaShopOptimized;

use Hestia\WebApp\Installers\BaseSetup as BaseSetup;
use function Hestiacp\quoteshellarg\quoteshellarg;

class PrestaShopOptimizedSetup extends BaseSetup {

    protected $appInfo = [
        "name"      => "PrestaShop Optimizado (QemuCP)",
        "group"     => "ecommerce",
        "enabled"   => true,
        "version"   => "8.1.7",
        "thumbnail" => "ps-qemucp-thumb.png",
    ];

    protected $appname = "prestashopoptimized";
    protected $extractsubdir = "/tmp-ps-qemucp";

    protected $config = [
        "form" => [
            "ps_firstname" => [
                "type"        => "text",
                "value"       => "Admin",
                "placeholder" => "Nombre administrador",
            ],
            "ps_lastname" => [
                "type"        => "text",
                "value"       => "QemuCP",
                "placeholder" => "Apellido administrador",
            ],
            "ps_email" => [
                "type"        => "text",
                "value"       => "",
                "placeholder" => "Email administrador",
            ],
            "ps_password" => [
                "type"        => "password",
                "value"       => "",
                "placeholder" => "Contrasena administrador",
            ],
            "ps_shop_name" => [
                "type"        => "text",
                "value"       => "Mi Tienda",
                "placeholder" => "Nombre de la tienda",
            ],
        ],
        "database" => true,
        "resources" => [
            "archive" => [
                "src" => "https://github.com/PrestaShop/PrestaShop/releases/download/8.1.7/prestashop_8.1.7.zip",
            ],
        ],
        "server" => [
            "nginx" => [
                "template" => "prestashop",
            ],
            "php" => [
                "supported" => ["8.1", "8.2", "8.3"],
            ],
        ],
    ];

    public function install(array $options = null): bool {
        $docroot = $this->getDocRoot();
        $domain  = $this->domain;

        $firstname  = $options["ps_firstname"] ?? "Admin";
        $lastname   = $options["ps_lastname"] ?? "QemuCP";
        $email      = $options["ps_email"] ?? "admin@" . $domain;
        $password   = $options["ps_password"] ?? bin2hex(random_bytes(8));
        $shop_name  = $options["ps_shop_name"] ?? "Mi Tienda";
        $db_name    = $this->appcontext->user() . "_" . ($options["database_name"] ?? "prestashop");
        $db_user    = $this->appcontext->user() . "_" . ($options["database_user"] ?? "prestashop");
        $db_pass    = $options["database_password"] ?? bin2hex(random_bytes(8));
        $db_host    = $options["database_host"] ?? "localhost";
        $db_prefix  = "ps_" . substr(md5(uniqid()), 0, 4) . "_";

        // Crear base de datos y descargar archivos
        parent::install($options);
        parent::setup($options);

        // Extraer el zip de PrestaShop
        $this->appcontext->archiveExtract(
            $this->getDocRoot($this->extractsubdir . "/prestashop.zip"),
            $this->getDocRoot()
        );

        // Verificar SSL
        $this->appcontext->runUser("v-list-web-domain", [$this->domain, "json"], $status);
        $ssl_enabled = ($status->code === 0 && $status->json[$this->domain]["SSL"] !== "no") ? 1 : 0;
        $protocol = $ssl_enabled ? "https" : "http";

        // PHP version
        $php_version = $options["php_version"] ?? "8.1";

        // Ejecutar instalador CLI de PrestaShop
        $this->appcontext->runUser(
            "v-run-cli-cmd",
            [
                "/usr/bin/php" . $php_version,
                quoteshellarg($this->getDocRoot("/install/index_cli.php")),
                "--db_server=" . quoteshellarg($db_host),
                "--db_user=" . quoteshellarg($db_user),
                "--db_password=" . quoteshellarg($db_pass),
                "--db_name=" . quoteshellarg($db_name),
                "--db_prefix=" . quoteshellarg($db_prefix),
                "--db_clear=1",
                "--domain=" . quoteshellarg($domain),
                "--base_uri=/",
                "--name=" . quoteshellarg($shop_name),
                "--country=es",
                "--timezone=Europe/Madrid",
                "--language=es",
                "--firstname=" . quoteshellarg($firstname),
                "--lastname=" . quoteshellarg($lastname),
                "--password=" . quoteshellarg($password),
                "--email=" . quoteshellarg($email),
                "--ssl=" . $ssl_enabled,
                "--rewrite=1",
                "--newsletter=0",
            ],
            $status
        );

        if ($status->code === 0) {
            $this->postInstall($docroot, $php_version);
        }

        return $status->code === 0;
    }

    private function postInstall(string $docroot, string $php_version): void {
        // Eliminar carpeta de instalacion (obligatorio por seguridad)
        exec("rm -rf " . quoteshellarg($docroot . "/install") . " 2>/dev/null");

        // Renombrar admin para mayor seguridad
        $new_admin = "admin_" . substr(md5(uniqid()), 0, 6);
        exec("mv " . quoteshellarg($docroot . "/admin") . " " . quoteshellarg($docroot . "/" . $new_admin) . " 2>/dev/null");

        // Crear fichero .htaccess para OPcache
        $htaccess = $docroot . "/.htaccess";
        if (!file_exists($htaccess)) {
            file_put_contents($htaccess, "# PrestaShop .htaccess - QemuCP\n");
        }

        // Configurar permisos correctos
        exec("find " . quoteshellarg($docroot) . " -type d -exec chmod 755 {} \\; 2>/dev/null");
        exec("find " . quoteshellarg($docroot) . " -type f -exec chmod 644 {} \\; 2>/dev/null");

        // Proteger ficheros sensibles
        exec("chmod 600 " . quoteshellarg($docroot . "/app/config/parameters.php") . " 2>/dev/null");
    }

    public function getDocRoot($append_relative_path = null): string {
        $homedir = $this->appcontext->user_home ?? "/home";
        $docroot = "/home/" . $this->appcontext->user() . "/web/" . $this->domain . "/public_html";
        return empty($append_relative_path) ? $docroot : $docroot . "/" . ltrim($append_relative_path, "/");
    }
}
