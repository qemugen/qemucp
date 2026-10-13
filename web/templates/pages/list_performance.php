<!-- QemuCP Performance Dashboard: datos de /api/performance-stats/ (JSON),
     con los componentes del panel (cards, units-table), no Bootstrap -->

<!-- Begin toolbar -->
<div class="toolbar">
	<div class="toolbar-inner">
		<div class="toolbar-buttons">
			<a class="button button-secondary button-back js-button-back" href="/list/server/">
				<i class="fas fa-arrow-left icon-blue"></i><?= tohtml(_("Back")) ?>
			</a>
		</div>
		<div class="toolbar-buttons">
			<button type="button" class="button button-secondary js-perf-refresh">
				<i class="fas fa-arrows-rotate icon-blue"></i><?= tohtml(_("Refresh")) ?>
			</button>
		</div>
	</div>
</div>
<!-- End toolbar -->

<div class="container">
	<h1 class="u-mt20 u-mb10"><?= tohtml(_("Server Performance")) ?></h1>
	<p class="u-mb20 js-perf-status"><?= tohtml(_("Updated every 10 seconds.")) ?></p>

	<div class="cards u-mb20">
		<div class="card">
			<div class="card-content">
				<p class="card-title"><?= tohtml(_("Processor")) ?></p>
				<p class="qemucp-perf-value js-perf" data-key="cpu" data-suffix="%">—</p>
				<p class="hint"><?= tohtml(_("Load average")) ?>: <span class="js-perf" data-key="load">—</span></p>
			</div>
		</div>
		<div class="card">
			<div class="card-content">
				<p class="card-title"><?= tohtml(_("Memory")) ?></p>
				<p class="qemucp-perf-value js-perf" data-key="ram_pct" data-suffix="%">—</p>
				<p class="hint"><span class="js-perf" data-key="ram_used">—</span> / <span class="js-perf" data-key="ram_total">—</span></p>
			</div>
		</div>
		<div class="card">
			<div class="card-content">
				<p class="card-title"><?= tohtml(_("Disk")) ?></p>
				<p class="qemucp-perf-value js-perf" data-key="disk_pct" data-suffix="%">—</p>
				<p class="hint"><span class="js-perf" data-key="disk_used">—</span> / <span class="js-perf" data-key="disk_total">—</span></p>
			</div>
		</div>
		<div class="card">
			<div class="card-content">
				<p class="card-title"><?= tohtml(_("Uptime")) ?></p>
				<p class="qemucp-perf-value js-perf" data-key="uptime">—</p>
				<p class="hint"><span class="js-perf" data-key="cores">—</span> <?= tohtml(_("cores")) ?></p>
			</div>
		</div>
	</div>

	<h2 class="u-mb10"><?= tohtml(_("Services")) ?></h2>
	<div class="units-table u-mb20">
		<div class="units-table-header">
			<div class="units-table-cell"><?= tohtml(_("Service")) ?></div>
			<div class="units-table-cell"><?= tohtml(_("Description")) ?></div>
			<div class="units-table-cell u-text-center"><?= tohtml(_("Status")) ?></div>
			<div class="units-table-cell u-text-center"><?= tohtml(_("CPU")) ?></div>
			<div class="units-table-cell u-text-center"><?= tohtml(_("Memory")) ?></div>
		</div>
		<div class="js-perf-services"></div>
	</div>

	<div class="js-perf-redis u-hidden">
		<h2 class="u-mb10"><?= tohtml(_("Cache (Redis)")) ?></h2>
		<div class="cards u-mb20">
			<div class="card"><div class="card-content"><p class="card-title"><?= tohtml(_("Memory")) ?></p><p class="qemucp-perf-value js-perf" data-key="redis.memory">—</p></div></div>
			<div class="card"><div class="card-content"><p class="card-title"><?= tohtml(_("Hit rate")) ?></p><p class="qemucp-perf-value js-perf" data-key="redis.hit_rate" data-suffix="%">—</p></div></div>
			<div class="card"><div class="card-content"><p class="card-title"><?= tohtml(_("Connections")) ?></p><p class="qemucp-perf-value js-perf" data-key="redis.clients">—</p></div></div>
		</div>
	</div>
</div>

<script>
(() => {
	const t = {
		running: <?= json_encode(_("Running")) ?>,
		stopped: <?= json_encode(_("Stopped")) ?>,
		error: <?= json_encode(_("The data could not be loaded.")) ?>,
		updated: <?= json_encode(_("Updated every 10 seconds.")) ?>,
	};
	const get = (obj, path) => path.split('.').reduce((o, k) => (o == null ? o : o[k]), obj);
	const cell = (text, cls = '') => {
		const div = document.createElement('div');
		div.className = 'units-table-cell ' + cls;
		div.textContent = text;
		return div;
	};

	function render(data) {
		document.querySelectorAll('.js-perf').forEach((el) => {
			const value = get(data, el.dataset.key);
			el.textContent = value == null ? '—' : value + (el.dataset.suffix || '');
		});
		const list = document.querySelector('.js-perf-services');
		list.replaceChildren(
			...(data.services || []).map((s) => {
				const row = document.createElement('div');
				row.className = 'units-table-row' + (s.active ? '' : ' disabled');
				row.append(cell(s.name, 'u-text-bold'), cell(s.system));
				const state = cell('', 'u-text-center-desktop');
				const badge = document.createElement('span');
				badge.className = 'units-table-badge ' + (s.active ? 'qemucp-badge-ok' : 'qemucp-badge-warning');
				badge.textContent = s.active ? t.running : t.stopped;
				state.append(badge);
				row.append(state, cell(s.cpu, 'u-text-center-desktop'), cell(s.mem, 'u-text-center-desktop'));
				return row;
			}),
		);
		document.querySelector('.js-perf-redis').classList.toggle('u-hidden', !data.redis);
		document.querySelector('.js-perf-status').textContent = t.updated;
	}

	function refresh() {
		fetch('/api/performance-stats/', { credentials: 'same-origin' })
			.then((r) => (r.ok ? r.json() : Promise.reject(r.status)))
			.then(render)
			.catch(() => {
				document.querySelector('.js-perf-status').textContent = t.error;
			});
	}

	document.querySelector('.js-perf-refresh').addEventListener('click', refresh);
	refresh();
	setInterval(refresh, 10000);
})();
</script>
