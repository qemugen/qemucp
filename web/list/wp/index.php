<?php
// QemuCP WP-TOOL: lista de las webs con WordPress del usuario.
// La deteccion la hace bin/v-qemucp-wp (como root): el panel corre como
// hestiaweb y no puede leer ni ejecutar nada dentro de /home/USUARIO.
// Ojo: $user ya viene entrecomillado (quoteshellarg en inc/main.php).
$TAB = "WP";

// Main include
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

exec(HESTIA_CMD . "v-qemucp-wp " . $user . " list", $output, $return_var);
$wp_sites = $return_var === 0 ? json_decode(implode("", $output), true) : [];
if (!is_array($wp_sites)) {
	$wp_sites = [];
}
unset($output);

// Webs del usuario donde se puede instalar una aplicacion
exec(HESTIA_CMD . "v-list-web-domains " . $user . " json", $output, $return_var);
$web_domains = $return_var === 0 ? json_decode(implode("", $output), true) : [];
$install_domains = [];
foreach (is_array($web_domains) ? $web_domains : [] as $domain => $domain_data) {
	if (($domain_data["SUSPENDED"] ?? "no") !== "yes") {
		$install_domains[] = $domain;
	}
}
unset($output);

// Catalogo del instalador de aplicaciones (mismo descubrimiento que
// web/add/webapp). Clave = carpeta del instalador. Las de QemuCP primero.
require_once $_SERVER["DOCUMENT_ROOT"] . "/src/init.php";
$hestia = new \Hestia\System\HestiaApp();
$apps = [];
foreach (glob($_SERVER["DOCUMENT_ROOT"] . "/src/app/WebApp/Installers/*/*Setup.php") as $file) {
	$app_dir = basename(dirname($file));
	$class = "\\Hestia\\WebApp\\Installers\\" . $app_dir . "\\" . $app_dir . "Setup";
	try {
		$apps[$app_dir] = (new $class($hestia))->getInfo();
	} catch (Throwable $e) {
		// Un instalador roto no debe tumbar la pagina entera
		trigger_error("QemuCP: instalador " . $app_dir . ": " . $e->getMessage());
	}
}
uksort($apps, function ($a, $b) {
	$qa = str_ends_with($a, "Optimized") ? 0 : 1;
	$qb = str_ends_with($b, "Optimized") ? 0 : 1;
	return $qa <=> $qb ?: strcasecmp($a, $b);
});

// Render page
render_page($user, $TAB, "list_wp");

// Back uri
$_SESSION["back"] = $_SERVER["REQUEST_URI"];
