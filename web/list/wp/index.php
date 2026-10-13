<?php
// QemuCP WP-TOOL: lista de las webs con WordPress del usuario.
// La deteccion la hace bin/v-qemucp-wp (como root): el panel corre como
// hestiaweb y no puede leer ni ejecutar nada dentro de /home/USUARIO.
$TAB = "WP";

// Main include
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

exec(HESTIA_CMD . "v-qemucp-wp " . quoteshellarg($user) . " list", $output, $return_var);
$wp_sites = $return_var === 0 ? json_decode(implode("", $output), true) : [];
if (!is_array($wp_sites)) {
	$wp_sites = [];
}
unset($output);

// Dominios sin WordPress: se ofrecen para instalarlo con el instalador de
// aplicaciones
exec(HESTIA_CMD . "v-list-web-domains " . quoteshellarg($user) . " json", $output, $return_var);
$web_domains = $return_var === 0 ? json_decode(implode("", $output), true) : [];
$domains_without_wp = [];
foreach (is_array($web_domains) ? $web_domains : [] as $domain => $domain_data) {
	if (!isset($wp_sites[$domain]) && ($domain_data["SUSPENDED"] ?? "no") !== "yes") {
		$domains_without_wp[] = $domain;
	}
}
unset($output);

// Render page
render_page($user, $TAB, "list_wp");

// Back uri
$_SESSION["back"] = $_SERVER["REQUEST_URI"];
