<?php
// QemuCP WP-TOOL: acciones sobre un WordPress (actualizar, mantenimiento,
// cache, copia). Las ejecuta bin/v-qemucp-wp como el propio usuario.
$TAB = "WP";

// Main include
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

// Check token
verify_csrf($_GET);

$actions = [
	"update" => _("WordPress, plugins and themes updated."),
	"maintenance-on" => _("Maintenance mode enabled."),
	"maintenance-off" => _("Maintenance mode disabled."),
	"flush-cache" => _("Cache cleared."),
	"backup" => _("Backup created in %s"),
];

$domain = $_GET["domain"] ?? "";
$action = $_GET["action"] ?? "";

if (empty($domain) || !array_key_exists($action, $actions)) {
	header("Location: /list/wp/");
	exit();
}

exec(
	HESTIA_CMD .
		"v-qemucp-wp " .
		$user .
		" " .
		quoteshellarg($action) .
		" " .
		quoteshellarg($domain),
	$output,
	$return_var,
);

if ($return_var === 0) {
	$message = $actions[$action];
	if ($action === "backup") {
		$file = end($output) ?: "";
		$message = sprintf($message, str_replace("/home/" . $user_plain . "/", "~/", $file));
	}
	$_SESSION["ok_msg"] = tohtml($domain) . ": " . tohtml($message);
} else {
	$_SESSION["error_msg"] =
		$domain .
		": " .
		_("The action could not be completed.") .
		" " .
		implode(" ", array_slice($output, -3));
}
unset($output);

header("Location: /list/wp/");
exit();
