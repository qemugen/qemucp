<?php
// QemuCP Performance Dashboard controller
$TAB = 'PERFORMANCE';

// Solo admin
if ($_SESSION['userContext'] !== 'admin') {
    header('Location: /list/web/');
    exit;
}

include $_SERVER['DOCUMENT_ROOT'] . '/inc/main.php';
render_page($user, $TAB, 'list_performance');
