<!-- Begin toolbar -->
<div class="toolbar">
	<div class="toolbar-inner">
		<div class="toolbar-buttons">
			<?php if ($read_only !== true) { ?>
				<a href="/add/web/" class="button button-secondary js-button-create">
					<i class="fas fa-circle-plus icon-green"></i><?= tohtml( _("Add Web Domain")) ?>
				</a>
			<?php } ?>
		</div>
		<div class="toolbar-right">
			<div class="toolbar-sorting">
				<button class="toolbar-sorting-toggle js-toggle-sorting-menu" type="button" title="<?= tohtml( _("Sort items")) ?>">
					<?= tohtml( _("Sort by")) ?>:
					<span class="u-text-bold">
							<?php if ($_SESSION['userSortOrder'] === 'name') { $label = _('Name'); } else { $label = _('Date'); } ?>
						<?= tohtml($label) ?> <i class="fas fa-arrow-down-a-z"></i>
					</span>
				</button>
				<ul class="toolbar-sorting-menu js-sorting-menu u-hidden">
					<li data-entity="sort-bandwidth" data-sort-as-int="1">
						<span class="name"><?= tohtml( _("Bandwidth")) ?> <i class="fas fa-arrow-down-a-z"></i></span><span class="up"><i class="fas fa-arrow-up-a-z"></i></span>
					</li>
					<li data-entity="sort-date" data-sort-as-int="1">
						<span class="name <?php if ($_SESSION['userSortOrder'] === 'date') { echo 'active'; } ?>"><?= tohtml( _("Date")) ?> <i class="fas fa-arrow-down-a-z"></i></span><span class="up"><i class="fas fa-arrow-up-a-z"></i></span>
					</li>
					<li data-entity="sort-disk" data-sort-as-int="1">
						<span class="name"><?= tohtml( _("Disk")) ?> <i class="fas fa-arrow-down-a-z"></i></span><span class="up"><i class="fas fa-arrow-up-a-z"></i></span>
					</li>
					<li data-entity="sort-name">
						<span class="name <?php if ($_SESSION['userSortOrder'] === 'name') { echo 'active'; } ?>"><?= tohtml( _("Name")) ?> <i class="fas fa-arrow-down-a-z"></i></span><span class="up"><i class="fas fa-arrow-up-a-z"></i></span>
					</li>
					<li data-entity="sort-ip" data-sort-as-int="1">
						<span class="name"><?= tohtml( _("IP Address")) ?> <i class="fas fa-arrow-down-a-z"></i></span><span class="up"><i class="fas fa-arrow-up-a-z"></i></span>
					</li>
				</ul>
				<?php if ($read_only !== true) { ?>
					<form x-data x-bind="BulkEdit" action="/bulk/web/" method="post">
						<input type="hidden" name="token" value="<?= tohtml($_SESSION["token"]) ?>">
						<select class="form-select" name="action">
							<option value=""><?= tohtml( _("Apply to selected")) ?></option>
							<?php if ($_SESSION["userContext"] === "admin") { ?>
								<option value="rebuild"><?= tohtml( _("Rebuild")) ?></option>
							<?php } ?>
							<option value="suspend"><?= tohtml( _("Suspend")) ?></option>
							<option value="unsuspend"><?= tohtml( _("Unsuspend")) ?></option>
							<?php if ($_SESSION["PROXY_SYSTEM"] == "nginx" || $_SESSION["WEB_SYSTEM"] == "nginx") { ?>
								<option value="purge"><?= tohtml( _("Purge Nginx Cache")) ?></option>
							<?php } ?>
							<option value="delete"><?= tohtml( _("Delete")) ?></option>
						</select>
						<button type="submit" class="toolbar-input-submit" title="<?= tohtml( _("Apply to selected")) ?>">
							<i class="fas fa-arrow-right"></i>
						</button>
					</form>
				<?php } ?>
			</div>
			<div class="toolbar-search">
				<form action="/search/" method="get">
					<input type="hidden" name="token" value="<?= tohtml($_SESSION["token"]) ?>">
					<input type="search" class="form-control js-search-input" name="q" value="<?= tohtml($_GET['q'] ?? '') ?>" title="<?= tohtml( _("Search")) ?>">
					<button type="submit" class="toolbar-input-submit" title="<?= tohtml( _("Search")) ?>">
						<i class="fas fa-magnifying-glass"></i>
					</button>
				</form>
			</div>
		</div>
	</div>
</div>
<!-- End toolbar -->

<?php
/*
 * QemuCP: lista de webs del tema qemucp (web/list/web/index.php la elige con
 * qemucp_theme_active(); los demas temas siguen con list_web.php).
 *
 * Lista sencilla: una fila por web. Al pulsarla se despliega su panel de
 * opciones con icono y texto, agrupadas como en Plesk. Cada subdominio va
 * justo debajo de su dominio (el dominio del usuario de nombre mas largo que
 * lo contiene).
 *
 * Se conservan las clases que usa el JavaScript del panel: js-unit (orden y
 * teclado), js-unit-checkbox (acciones masivas), units-table-row-action con
 * shortcut-* (atajos de teclado) y js-confirm-action (confirmaciones).
 */
$data = is_array($data) ? $data : [];
$qemucp_mail = is_array($qemucp_mail ?? null) ? $qemucp_mail : [];
$qemucp_dns = is_array($qemucp_dns ?? null) ? $qemucp_dns : [];

// Subdominios bajo su dominio, en el orden elegido para los dominios
$qemucp_parent = [];
foreach (array_keys($data) as $qemucp_d) {
	foreach (array_keys($data) as $qemucp_p) {
		if (
			$qemucp_p !== $qemucp_d &&
			str_ends_with($qemucp_d, "." . $qemucp_p) &&
			strlen($qemucp_p) > strlen($qemucp_parent[$qemucp_d] ?? "")
		) {
			$qemucp_parent[$qemucp_d] = $qemucp_p;
		}
	}
}
$qemucp_children = [];
foreach ($qemucp_parent as $qemucp_d => $qemucp_p) {
	$qemucp_children[$qemucp_p][] = $qemucp_d;
}
$qemucp_ordered = [];
$qemucp_depth = [];
$qemucp_add = function ($d, $depth) use (&$qemucp_add, &$qemucp_ordered, &$qemucp_depth, $qemucp_children, $data) {
	$qemucp_ordered[$d] = $data[$d];
	$qemucp_depth[$d] = $depth;
	$children = $qemucp_children[$d] ?? [];
	sort($children);
	foreach ($children as $child) {
		$qemucp_add($child, $depth + 1);
	}
};
foreach (array_keys($data) as $qemucp_d) {
	if (!isset($qemucp_parent[$qemucp_d])) {
		$qemucp_add($qemucp_d, 0);
	}
}

// Tamano legible: "812 MB", "4.1 GB" (sin ".00" ni unidades en minusculas)
$qemucp_size = function ($v) {
	return preg_replace("/\.0$/", "", humanize_usage_size($v, 1)) . " " . strtoupper((string) humanize_usage_measure($v));
};

// Una opcion del panel: icono + texto
$qemucp_tile = function ($href, $icon, $label, $extra = []) {
	$attrs = "";
	foreach ($extra as $name => $value) {
		$attrs .= " " . $name . '="' . tohtml($value) . '"';
	}
	return '<a class="qemucp-tile' . (isset($extra["data-confirm-title"]) ? " data-controls js-confirm-action" : "") . '" href="' .
		tohtml($href) . '"' . $attrs . '><span class="qemucp-tile-icon"><i class="fas ' . tohtml($icon) . '"></i></span><span class="qemucp-tile-label">' .
		tohtml($label) . "</span></a>";
};
?>

<div class="container qemucp-page">

	<h1 class="u-mt20 u-mb10"><?= tohtml(_("Websites")) ?></h1>
	<p class="u-mb20 hint"><?= tohtml(_("Click on a website to see all its options.")) ?></p>

	<?php if (empty($qemucp_ordered)) { ?>
		<div class="inline-alert inline-alert-warning u-mb20" role="status">
			<i class="fas fa-circle-info"></i>
			<p><?= tohtml(_("You have no websites yet.")) ?> <a href="/add/web/"><?= tohtml(_("Add Web Domain")) ?></a></p>
		</div>
	<?php } ?>

	<?php if (!empty($qemucp_ordered) && $read_only !== true) { ?>
		<label class="qemucp-select-all">
			<input type="checkbox" class="js-toggle-all-checkbox">
			<?= tohtml(_("Select all")) ?>
			<span class="hint">(<?= tohtml(_("to suspend or delete several at once from the menu above")) ?>)</span>
		</label>
	<?php } ?>

	<div class="qemucp-sites js-units-container">
		<?php
		$i = 0;
		foreach ($qemucp_ordered as $key => $site) {
			++$i;
			$is_sub = isset($qemucp_parent[$key]);
			$suspended = ($site["SUSPENDED"] ?? "no") === "yes";
			$has_ssl = ($site["SSL"] ?? "no") === "yes";
			$url = ($has_ssl ? "https" : "http") . "://" . $key . "/";
			$edit = "/edit/web/?" . http_build_query(["domain" => $key, "token" => $_SESSION["token"]]);
			$aliases = array_values(array_filter(
				array_map("trim", explode(",", $site["ALIAS"] ?? "")),
				fn($a) => $a !== "" && $a !== "www." . $key,
			));
			$php = !empty($site["BACKEND"]) ? qemucp_backend_label($site["BACKEND"]) : "";
			// Clave de orden = cadena desde el dominio raiz ("qemucp.com
			// tienda.qemucp.com api.tienda.qemucp.com"): ordenar por nombre
			// mantiene juntos el dominio y todos sus subdominios
			$sort_name = $key;
			for ($p = $key; isset($qemucp_parent[$p]); $p = $qemucp_parent[$p]) {
				$sort_name = $qemucp_parent[$p] . " " . $sort_name;
			}
			$ip = empty($ips[$site["IP"]]["NAT"] ?? "") ? $site["IP"] ?? "" : $ips[$site["IP"]]["NAT"];
			?>
			<details class="qemucp-site js-unit<?= $suspended ? " is-suspended" : "" ?><?= $is_sub ? " is-sub qemucp-depth-" . min(3, $qemucp_depth[$key]) : "" ?>"
				data-sort-ip="<?= tohtml(str_replace(".", "", $site["IP"] ?? "")) ?>"
				data-sort-date="<?= tohtml(strtotime(($site["DATE"] ?? "") . " " . ($site["TIME"] ?? ""))) ?>"
				data-sort-name="<?= tohtml($sort_name) ?>"
				data-sort-bandwidth="<?= tohtml($site["U_BANDWIDTH"] ?? 0) ?>"
				data-sort-disk="<?= tohtml($site["U_DISK"] ?? 0) ?>">
				<summary class="qemucp-site-summary">
					<input id="check<?= tohtml($i) ?>" class="js-unit-checkbox qemucp-site-check" type="checkbox" title="<?= tohtml(_("Select")) ?>" name="domain[]" value="<?= tohtml($key) ?>"<?= $read_only === true ? " disabled" : "" ?>>
					<span class="qemucp-site-icon"><i class="fas <?= $is_sub ? "fa-turn-up fa-rotate-90" : "fa-globe" ?>"></i></span>
					<span class="qemucp-site-name">
						<span class="qemucp-site-title">
							<?php if ($is_sub) { ?>
								<strong><?= tohtml(substr($key, 0, -strlen($qemucp_parent[$key]) - 1)) ?></strong><span class="qemucp-domain-parent">.<?= tohtml($qemucp_parent[$key]) ?></span>
							<?php } else { ?>
								<strong><?= tohtml($key) ?></strong>
							<?php } ?>
						</span>
						<?php if (!empty($aliases)) { ?>
							<span class="qemucp-site-aliases" title="<?= tohtml(implode(", ", $aliases)) ?>"><?= tohtml(_("Also answers to")) ?>: <?= tohtml(implode(", ", $aliases)) ?></span>
						<?php } ?>
					</span>
					<span class="qemucp-site-tags">
						<?php if ($suspended) { ?>
							<span class="qemucp-tag is-danger"><?= tohtml(_("Suspended")) ?></span>
						<?php } ?>
						<?php if ($is_sub) { ?>
							<span class="qemucp-tag is-info"><?= tohtml(_("Subdomain")) ?></span>
						<?php } elseif (!empty($qemucp_children[$key])) { ?>
							<span class="qemucp-tag"><?= tohtml(count($qemucp_children[$key]) === 1 ? _("1 subdomain") : sprintf(_("%d subdomains"), count($qemucp_children[$key]))) ?></span>
						<?php } ?>
						<span class="qemucp-tag <?= $has_ssl ? "is-ok" : "is-warning" ?>" title="<?= tohtml($has_ssl ? _("Secure connection (HTTPS)") : _("No SSL certificate")) ?>">
							<i class="fas <?= $has_ssl ? "fa-lock" : "fa-lock-open" ?>"></i> <?= tohtml($has_ssl ? "HTTPS" : _("No SSL")) ?>
						</span>
						<?php if ($php !== "") { ?>
							<span class="qemucp-tag" title="<?= tohtml(_("PHP Version")) ?>"><?= tohtml($php) ?></span>
						<?php } ?>
					</span>
					<span class="qemucp-site-usage" title="<?= tohtml(_("Disk")) ?>">
						<i class="fas fa-hard-drive"></i>
						<?= tohtml($qemucp_size($site["U_DISK"] ?? 0)) ?>
					</span>
					<span class="qemucp-site-chevron"><i class="fas fa-chevron-down"></i></span>
				</summary>

				<div class="qemucp-site-panel">
					<ul class="units-table-row-actions qemucp-site-groups">
						<li class="qemucp-group">
							<p class="qemucp-group-title"><?= tohtml(_("Website")) ?></p>
							<div class="units-table-row-action" data-key-action="href"><?= $qemucp_tile($url, "fa-arrow-up-right-from-square", _("Visit website"), ["target" => "_blank", "rel" => "noopener"]) ?></div>
							<?php if ($read_only !== true && !$suspended) { ?>
								<div class="units-table-row-action shortcut-enter" data-key-action="href"><?= $qemucp_tile($edit, "fa-pen-to-square", _("Edit settings")) ?></div>
								<div class="units-table-row-action"><?= $qemucp_tile($edit, "fa-code", _("PHP Version")) ?></div>
								<div class="units-table-row-action"><?= $qemucp_tile($edit, "fa-shield-halved", _("SSL / HTTPS")) ?></div>
								<div class="units-table-row-action"><?= $qemucp_tile("/add/webapp/?" . http_build_query(["domain" => $key]), "fa-cubes", _("Install application")) ?></div>
							<?php } ?>
						</li>
						<li class="qemucp-group">
							<p class="qemucp-group-title"><?= tohtml(_("Files and data")) ?></p>
							<?php if (!empty($_SESSION["FILE_MANAGER"]) && $_SESSION["FILE_MANAGER"] !== "false") { ?>
								<div class="units-table-row-action"><?= $qemucp_tile("/fm/", "fa-folder-open", _("File manager")) ?></div>
							<?php } ?>
							<div class="units-table-row-action"><?= $qemucp_tile("/list/db/", "fa-database", _("Databases")) ?></div>
							<?php if ($read_only !== true && !$suspended) { ?>
								<div class="units-table-row-action" data-key-action="href"><?= $qemucp_tile("/download/site/?" . http_build_query(["site" => $key, "token" => $_SESSION["token"]]), "fa-download", _("Download copy")) ?></div>
							<?php } ?>
						</li>
						<li class="qemucp-group">
							<p class="qemucp-group-title"><?= tohtml(_("Mail and DNS")) ?></p>
							<?php if (isset($qemucp_mail[$key])) { ?>
								<div class="units-table-row-action"><?= $qemucp_tile("/list/mail/?" . http_build_query(["domain" => $key, "token" => $_SESSION["token"]]), "fa-envelope", _("Email accounts")) ?></div>
							<?php } elseif ($read_only !== true) { ?>
								<div class="units-table-row-action"><?= $qemucp_tile("/add/mail/", "fa-envelope", _("Set up email")) ?></div>
							<?php } ?>
							<?php if (isset($qemucp_dns[$key])) { ?>
								<div class="units-table-row-action"><?= $qemucp_tile("/list/dns/?" . http_build_query(["domain" => $key, "token" => $_SESSION["token"]]), "fa-book-atlas", _("DNS records")) ?></div>
							<?php } ?>
						</li>
						<li class="qemucp-group">
							<p class="qemucp-group-title"><?= tohtml(_("Statistics and logs")) ?></p>
							<?php if (!empty($site["STATS"])) { ?>
								<div class="units-table-row-action shortcut-w" data-key-action="href"><?= $qemucp_tile($url . "vstats/", "fa-chart-column", _("Statistics"), ["target" => "_blank", "rel" => "noopener"]) ?></div>
							<?php } ?>
							<div class="units-table-row-action shortcut-l" data-key-action="href"><?= $qemucp_tile("/list/web-log/?" . http_build_query(["domain" => $key, "type" => "access"]), "fa-file-lines", _("Visits log")) ?></div>
							<div class="units-table-row-action"><?= $qemucp_tile("/list/web-log/?" . http_build_query(["domain" => $key, "type" => "error"]), "fa-triangle-exclamation", _("Errors log")) ?></div>
						</li>
					</ul>

					<div class="qemucp-site-footer">
						<span class="hint">
							<?= tohtml(_("IP Address")) ?>: <?= tohtml($ip) ?> ·
							<?= tohtml(_("Bandwidth")) ?>: <?= tohtml($qemucp_size($site["U_BANDWIDTH"] ?? 0)) ?>
						</span>
						<?php if ($read_only !== true) { ?>
							<span class="qemucp-site-danger">
								<?php if ($suspended) { ?>
									<span class="units-table-row-action shortcut-s" data-key-action="js"><?= $qemucp_tile("/unsuspend/web/?" . http_build_query(["domain" => $key, "token" => $_SESSION["token"]]), "fa-play", _("Unsuspend"), ["data-confirm-title" => _("Unsuspend"), "data-confirm-message" => sprintf(_("Are you sure you want to unsuspend domain %s?"), $key)]) ?></span>
								<?php } else { ?>
									<span class="units-table-row-action shortcut-s" data-key-action="js"><?= $qemucp_tile("/suspend/web/?" . http_build_query(["domain" => $key, "token" => $_SESSION["token"]]), "fa-pause", _("Suspend"), ["data-confirm-title" => _("Suspend"), "data-confirm-message" => sprintf(_("Are you sure you want to suspend domain %s?"), $key)]) ?></span>
								<?php } ?>
								<span class="units-table-row-action shortcut-delete is-delete" data-key-action="js"><?= $qemucp_tile("/delete/web/?" . http_build_query(["domain" => $key, "token" => $_SESSION["token"]]), "fa-trash", _("Delete"), ["data-confirm-title" => _("Delete"), "data-confirm-message" => sprintf(_("Are you sure you want to delete domain %s?"), $key)]) ?></span>
							</span>
						<?php } ?>
					</div>
				</div>
			</details>
		<?php } ?>
	</div>

	<div class="units-table-footer">
		<p><?php printf(ngettext("%d web domain", "%d web domains", $i), $i); ?></p>
	</div>

</div>
