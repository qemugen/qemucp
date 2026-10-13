<?php
$TAB = "WEB";

// Main include
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

// Data
exec(HESTIA_CMD . "v-list-web-domains " . $user . " 'json'", $output, $return_var);
$data = json_decode(implode("", $output), true);
if ($_SESSION["userSortOrder"] == "name") {
	ksort($data);
} else {
	$data = array_reverse($data, true);
}
$ips = json_decode(shell_exec(HESTIA_CMD . "v-list-sys-ips json"), true);

// Render page
if (qemucp_theme_active()) {
	// QemuCP: lista sencilla que se despliega con las opciones de cada web
	// (web/templates/pages/list_web_qemucp.php). Necesita saber que dominios
	// tienen correo y DNS para enlazar directamente a ellos.
	exec(HESTIA_CMD . "v-list-mail-domains " . $user . " json", $output, $return_var);
	$qemucp_mail = $return_var === 0 ? json_decode(implode("", $output), true) : [];
	unset($output);
	exec(HESTIA_CMD . "v-list-dns-domains " . $user . " json", $output, $return_var);
	$qemucp_dns = $return_var === 0 ? json_decode(implode("", $output), true) : [];
	unset($output);
	render_page($user, $TAB, "list_web_qemucp");
} else {
	render_page($user, $TAB, "list_web");
}

// Back uri
$_SESSION["back"] = $_SERVER["REQUEST_URI"];
