<?php
// list_wp.php - WordPress Manager para QemuCP
// Variable $wp_sites viene del controlador
?>

<div class="toolbar">
    <div class="toolbar-inner">
        <div class="toolbar-buttons">
            <a class="button" href="/list/web/">
                <i class="fas fa-arrow-left"></i> <?= _("Back to Web") ?>
            </a>
        </div>
        <div class="toolbar-right">
            <p><?= _("WordPress Manager") ?></p>
        </div>
    </div>
</div>

<div class="container">
    <?php if (empty($wp_sites)): ?>
    <div class="u-mt20">
        <div class="alert alert-info">
            <i class="fas fa-info-circle"></i>
            <?= _("No WordPress installations found. Install WordPress using Quick Install.") ?>
        </div>
        <div class="u-mt10">
            <a class="button" href="/list/web/">
                <i class="fas fa-plus"></i> <?= _("Go to Web Domains") ?>
            </a>
        </div>
    </div>
    <?php else: ?>

    <div class="units-table js-units-container">
        <div class="units-table-header">
            <div class="units-table-cell"><?= _("Domain") ?></div>
            <div class="units-table-cell"><?= _("WP Version") ?></div>
            <div class="units-table-cell"><?= _("SSL") ?></div>
            <div class="units-table-cell"><?= _("Status") ?></div>
            <div class="units-table-cell"><?= _("Actions") ?></div>
        </div>

        <?php foreach ($wp_sites as $domain => $wp): ?>
        <div class="units-table-row">
            <div class="units-table-cell">
                <i class="fab fa-wordpress icon-blue u-mr5"></i>
                <a href="https://<?= htmlspecialchars($domain) ?>" target="_blank">
                    <?= htmlspecialchars($domain) ?>
                </a>
            </div>
            <div class="units-table-cell">
                <span class="badge <?= ($wp['version'] !== 'unknown') ? 'u-bg-green' : 'u-bg-orange' ?>">
                    <?= htmlspecialchars($wp['version']) ?>
                </span>
            </div>
            <div class="units-table-cell">
                <?php if ($wp['ssl'] !== 'no'): ?>
                    <i class="fas fa-lock icon-green"></i> SSL
                <?php else: ?>
                    <i class="fas fa-lock-open icon-dim"></i> <?= _("No SSL") ?>
                <?php endif; ?>
            </div>
            <div class="units-table-cell">
                <?php if ($wp['suspended'] === 'yes'): ?>
                    <span class="badge u-bg-red"><?= _("Suspended") ?></span>
                <?php else: ?>
                    <span class="badge u-bg-green"><?= _("Active") ?></span>
                <?php endif; ?>
            </div>
            <div class="units-table-cell">
                <div class="units-table-row-actions">
                    <!-- Actualizar WP -->
                    <a class="units-table-row-action-link u-mr5"
                       href="/edit/wp/?domain=<?= urlencode($domain) ?>&action=update"
                       title="<?= _("Update WordPress") ?>"
                       onclick="return confirm('<?= _("Update WordPress core?") ?>')">
                        <i class="fas fa-arrow-up-from-bracket"></i> <?= _("Update") ?>
                    </a>
                    <!-- Mantenimiento -->
                    <a class="units-table-row-action-link u-mr5"
                       href="/edit/wp/?domain=<?= urlencode($domain) ?>&action=maintenance_on"
                       title="<?= _("Enable Maintenance Mode") ?>">
                        <i class="fas fa-triangle-exclamation"></i> <?= _("Maintenance") ?>
                    </a>
                    <!-- Cache -->
                    <a class="units-table-row-action-link u-mr5"
                       href="/edit/wp/?domain=<?= urlencode($domain) ?>&action=flush_cache"
                       title="<?= _("Flush Cache") ?>"
                       onclick="return confirm('<?= _("Flush WordPress cache?") ?>')">
                        <i class="fas fa-broom"></i> <?= _("Flush Cache") ?>
                    </a>
                    <!-- Backup -->
                    <a class="units-table-row-action-link"
                       href="/edit/wp/?domain=<?= urlencode($domain) ?>&action=backup"
                       title="<?= _("Backup WordPress") ?>"
                       onclick="return confirm('<?= _("Create WordPress backup?") ?>')">
                        <i class="fas fa-file-zipper"></i> <?= _("Backup") ?>
                    </a>
                </div>
            </div>
        </div>
        <?php endforeach; ?>
    </div>

    <?php endif; ?>
</div>
