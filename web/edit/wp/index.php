<?php
$TAB = "WP";

// Main include
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

$domain  = isset($_GET["domain"]) ? escapeshellcmd($_GET["domain"]) : "";
$action  = isset($_GET["action"]) ? $_GET["action"] : "";
$docroot = "/home/" . $user . "/web/" . $domain . "/public_html";
$wp_cli  = "/usr/local/bin/wp";
$result  = "";
$status  = "success";

// Verificar que el dominio pertenece al usuario
exec(HESTIA_CMD . "v-list-web-domain " . $user . " " . quoteshellarg($domain) . " 'json'", $output, $return_var);
if ($return_var !== 0) {
    header("Location: /list/wp/");
    exit;
}
$output = [];

if (!file_exists($wp_cli)) {
    $result = "WP-CLI not found. Please install it first.";
    $status = "error";
} elseif (!empty($action) && !empty($domain)) {
    $wp_base = "sudo -u " . $user . " " . $wp_cli . " --path=" . quoteshellarg($docroot) . " --allow-root";

    switch ($action) {
        case "update":
            exec($wp_base . " core update 2>&1", $out, $rc);
            exec($wp_base . " plugin update --all 2>&1", $out2, $rc2);
            exec($wp_base . " theme update --all 2>&1", $out3, $rc3);
            $result = implode("\n", array_merge($out, $out2, $out3));
            $status = ($rc === 0) ? "success" : "error";
            break;

        case "maintenance_on":
            exec($wp_base . " maintenance-mode activate 2>&1", $out, $rc);
            $result = implode("\n", $out);
            $status = ($rc === 0) ? "success" : "error";
            break;

        case "maintenance_off":
            exec($wp_base . " maintenance-mode deactivate 2>&1", $out, $rc);
            $result = implode("\n", $out);
            $status = ($rc === 0) ? "success" : "error";
            break;

        case "flush_cache":
            exec($wp_base . " cache flush 2>&1", $out, $rc);
            exec($wp_base . " rewrite flush 2>&1", $out2, $rc2);
            $result = implode("\n", array_merge($out, $out2));
            $status = ($rc === 0) ? "success" : "error";
            break;

        case "backup":
            $backup_dir = "/home/" . $user . "/wp-backups";
            $date = date("Y-m-d_H-i-s");
            $backup_file = $backup_dir . "/" . $domain . "_" . $date . ".tar.gz";
            exec("mkdir -p " . quoteshellarg($backup_dir));
            // DB backup
            $db_file = "/tmp/" . $domain . "_db_" . $date . ".sql";
            exec($wp_base . " db export " . quoteshellarg($db_file) . " 2>&1", $out, $rc);
            // Files + DB backup
            exec("tar -czf " . quoteshellarg($backup_file) . " -C " . quoteshellarg($docroot) . " . " . quoteshellarg($db_file) . " 2>&1", $out2, $rc2);
            exec("rm -f " . quoteshellarg($db_file));
            exec("chown " . $user . ":" . $user . " " . quoteshellarg($backup_file));
            $result = "Backup created: " . $backup_file;
            $status = ($rc === 0 && $rc2 === 0) ? "success" : "error";
            break;

        case "get_info":
            exec($wp_base . " core version 2>&1", $out, $rc);
            exec($wp_base . " plugin list --format=json 2>&1", $out2, $rc2);
            exec($wp_base . " theme list --format=json 2>&1", $out3, $rc3);
            $result = json_encode([
                "version" => implode("", $out),
                "plugins" => json_decode(implode("", $out2), true),
                "themes"  => json_decode(implode("", $out3), true),
            ]);
            $status = "success";
            break;
    }
}

// Redirect back with message
$_SESSION["error"] = ($status === "error") ? $result : "";
$_SESSION["ok"]    = ($status === "success") ? ($result ?: "Action completed successfully") : "";
header("Location: /list/wp/");
exit;
