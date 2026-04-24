<?php
$TAB = "WP";

// Main include
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

// Obtener todos los dominios web del usuario
exec(HESTIA_CMD . "v-list-web-domains " . $user . " 'json'", $output, $return_var);
$web_domains = json_decode(implode("", $output), true);
$output = [];

// Detectar cuales tienen WordPress instalado
$wp_sites = [];
foreach ($web_domains as $domain => $domain_data) {
    $docroot = "/home/" . $user . "/web/" . $domain . "/public_html";
    $wp_config = $docroot . "/wp-config.php";
    $wp_login = $docroot . "/wp-login.php";

    if (file_exists($wp_config) || file_exists($wp_login)) {
        // Obtener version de WP
        $wp_version = "unknown";
        $version_file = $docroot . "/wp-includes/version.php";
        if (file_exists($version_file)) {
            $version_content = file_get_contents($version_file);
            preg_match('/\$wp_version\s*=\s*[\'"]([^\'"]+)[\'"]/', $version_content, $matches);
            $wp_version = $matches[1] ?? "unknown";
        }

        // Verificar si hay actualizacion disponible (via wp-cli si disponible)
        $wp_sites[$domain] = [
            "version"  => $wp_version,
            "ssl"      => $domain_data["SSL"] ?? "no",
            "suspended"=> $domain_data["SUSPENDED"] ?? "no",
            "docroot"  => $docroot,
        ];
    }
}

// Render page
render_page($user, $TAB, "list_wp", $wp_sites);

// Back uri
$_SESSION["back"] = $_SERVER["REQUEST_URI"];
