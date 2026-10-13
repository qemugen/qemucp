<?php
// QemuCP Performance Dashboard (solo administradores)
$TAB = "PERFORMANCE";

// Main include: arranca la sesion y comprueba el login. Hay que cargarlo
// ANTES de mirar $_SESSION (antes se miraba antes y siempre redirigia).
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

if (($_SESSION["userContext"] ?? "") !== "admin") {
	header("Location: /list/web/");
	exit();
}

render_page($user, $TAB, "list_performance");
