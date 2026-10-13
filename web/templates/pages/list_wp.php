<!-- QemuCP WP-TOOL: $wp_sites y $domains_without_wp vienen de web/list/wp/index.php -->

<!-- Begin toolbar -->
<div class="toolbar">
	<div class="toolbar-inner">
		<div class="toolbar-buttons">
			<a class="button button-secondary button-back js-button-back" href="/list/web/">
				<i class="fas fa-arrow-left icon-blue"></i><?= tohtml(_("Back")) ?>
			</a>
		</div>
	</div>
</div>
<!-- End toolbar -->

<div class="container">

	<h1 class="u-mt20 u-mb20"><?= tohtml(_("WordPress")) ?></h1>
	<?php show_alert_message($_SESSION); ?>

	<?php if (!empty($wp_sites)) { ?>
		<div class="units-table js-units-container">
			<div class="units-table-header">
				<div class="units-table-cell"><?= tohtml(_("Website")) ?></div>
				<div class="units-table-cell"></div>
				<div class="units-table-cell u-text-center"><?= tohtml(_("Version")) ?></div>
				<div class="units-table-cell u-text-center"><?= tohtml(_("Status")) ?></div>
				<div class="units-table-cell u-text-center"><?= tohtml(_("SSL")) ?></div>
			</div>

			<?php foreach ($wp_sites as $domain => $wp) {
				$suspended = ($wp["SUSPENDED"] ?? "no") === "yes";
				$maintenance = ($wp["MAINTENANCE"] ?? "no") === "yes";
				$scheme = ($wp["SSL"] ?? "no") === "yes" ? "https" : "http";
				$site_url = $scheme . "://" . $domain . "/";
				$wp_action = function ($action) use ($domain) {
					return "/edit/wp/?" . http_build_query(["domain" => $domain, "action" => $action, "token" => $_SESSION["token"]]);
				};
				?>
				<div class="units-table-row <?= $suspended ? "disabled" : "" ?> js-unit">
					<div class="units-table-cell units-table-heading-cell u-text-bold">
						<span class="u-hide-desktop"><?= tohtml(_("Website")) ?>:</span>
						<a href="<?= tohtml($site_url) ?>" target="_blank" rel="noopener"><?= tohtml($domain) ?></a>
					</div>
					<div class="units-table-cell">
						<ul class="units-table-row-actions">
							<li class="units-table-row-action" data-key-action="href">
								<a class="units-table-row-action-link" href="<?= tohtml($site_url) ?>" target="_blank" rel="noopener" title="<?= tohtml(_("Visit")) ?>">
									<i class="fas fa-square-up-right icon-lightblue"></i>
									<span class="u-hide-desktop"><?= tohtml(_("Visit")) ?></span>
								</a>
							</li>
							<li class="units-table-row-action shortcut-enter" data-key-action="href">
								<a class="units-table-row-action-link" href="<?= tohtml($site_url . "wp-admin/") ?>" target="_blank" rel="noopener" title="<?= tohtml(_("Open WordPress")) ?>">
									<i class="fas fa-right-to-bracket icon-blue"></i>
									<span class="u-hide-desktop"><?= tohtml(_("Open WordPress")) ?></span>
								</a>
							</li>
							<?php if ($read_only !== true && !$suspended) { ?>
								<li class="units-table-row-action" data-key-action="js">
									<a
										class="units-table-row-action-link data-controls js-confirm-action"
										href="<?= tohtml($wp_action("update")) ?>"
										title="<?= tohtml(_("Update all")) ?>"
										data-confirm-title="<?= tohtml(_("Update all")) ?>"
										data-confirm-message="<?= tohtml(sprintf(_("Update WordPress, plugins and themes of %s? Make a backup first if you are not sure."), $domain)) ?>"
									>
										<i class="fas fa-arrows-rotate icon-green"></i>
										<span class="u-hide-desktop"><?= tohtml(_("Update all")) ?></span>
									</a>
								</li>
								<li class="units-table-row-action" data-key-action="js">
									<a
										class="units-table-row-action-link data-controls js-confirm-action"
										href="<?= tohtml($wp_action("backup")) ?>"
										title="<?= tohtml(_("Make backup")) ?>"
										data-confirm-title="<?= tohtml(_("Make backup")) ?>"
										data-confirm-message="<?= tohtml(sprintf(_("Make a backup of %s (files and database)?"), $domain)) ?>"
									>
										<i class="fas fa-file-zipper icon-purple"></i>
										<span class="u-hide-desktop"><?= tohtml(_("Make backup")) ?></span>
									</a>
								</li>
								<li class="units-table-row-action" data-key-action="href">
									<a class="units-table-row-action-link" href="<?= tohtml($wp_action("flush-cache")) ?>" title="<?= tohtml(_("Clear cache")) ?>">
										<i class="fas fa-broom icon-orange"></i>
										<span class="u-hide-desktop"><?= tohtml(_("Clear cache")) ?></span>
									</a>
								</li>
								<li class="units-table-row-action shortcut-s" data-key-action="js">
									<?php $maint_title = $maintenance ? _("End maintenance") : _("Maintenance mode"); ?>
									<a
										class="units-table-row-action-link data-controls js-confirm-action"
										href="<?= tohtml($wp_action($maintenance ? "maintenance-off" : "maintenance-on")) ?>"
										title="<?= tohtml($maint_title) ?>"
										data-confirm-title="<?= tohtml($maint_title) ?>"
										data-confirm-message="<?= tohtml(sprintf($maintenance ? _("Make %s visible to visitors again?") : _("Show a maintenance notice to the visitors of %s?"), $domain)) ?>"
									>
										<i class="fas fa-<?= $maintenance ? "play" : "pause" ?> icon-highlight"></i>
										<span class="u-hide-desktop"><?= tohtml($maint_title) ?></span>
									</a>
								</li>
							<?php } ?>
						</ul>
					</div>
					<div class="units-table-cell u-text-center-desktop">
						<span class="u-hide-desktop u-text-bold"><?= tohtml(_("Version")) ?>:</span>
						<?= tohtml($wp["VERSION"] !== "" ? $wp["VERSION"] : "—") ?>
					</div>
					<div class="units-table-cell u-text-center-desktop">
						<span class="u-hide-desktop u-text-bold"><?= tohtml(_("Status")) ?>:</span>
						<?php if ($suspended) { ?>
							<span class="units-table-badge"><?= tohtml(_("Suspended")) ?></span>
						<?php } elseif ($maintenance) { ?>
							<span class="units-table-badge qemucp-badge-warning"><?= tohtml(_("In maintenance")) ?></span>
						<?php } else { ?>
							<span class="units-table-badge qemucp-badge-ok"><?= tohtml(_("Active")) ?></span>
						<?php } ?>
					</div>
					<div class="units-table-cell u-text-center-desktop">
						<span class="u-hide-desktop u-text-bold"><?= tohtml(_("SSL")) ?>:</span>
						<i class="fas <?= ($wp["SSL"] ?? "no") === "yes" ? "fa-circle-check icon-green" : "fa-circle-xmark icon-red" ?>"></i>
					</div>
				</div>
			<?php } ?>
		</div>
	<?php } else { ?>
		<div class="inline-alert inline-alert-warning u-mb20" role="status">
			<i class="fas fa-circle-info"></i>
			<p><?= tohtml(_("No WordPress has been found in your websites yet.")) ?></p>
		</div>
	<?php } ?>

	<?php if ($read_only !== true && !empty($domains_without_wp)) { ?>
		<h2 class="u-mt20 u-mb10"><?= tohtml(_("Install WordPress")) ?></h2>
		<p class="u-mb10"><?= tohtml(_("Choose the website where you want to install it:")) ?></p>
		<div class="toolbar-buttons u-mb20">
			<?php foreach ($domains_without_wp as $domain) { ?>
				<a class="button button-secondary u-mb10" href="/add/webapp/?<?= tohtml(http_build_query(["domain" => $domain])) ?>">
					<i class="fas fa-plus icon-green"></i><?= tohtml(sprintf(_("Install WordPress in %s"), $domain)) ?>
				</a>
			<?php } ?>
		</div>
	<?php } ?>

</div>
