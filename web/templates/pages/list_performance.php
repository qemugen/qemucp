<!-- QemuCP Performance Dashboard -->
<div class="toolbar">
    <div class="toolbar-inner">
        <div class="toolbar-buttons">
            <span class="toolbar-title"><?= _("Server Performance") ?></span>
        </div>
        <div class="toolbar-buttons">
            <button onclick="refreshStats()" class="button button-secondary">
                <i class="fas fa-sync icon-blue"></i><?= _("Refresh") ?>
            </button>
        </div>
    </div>
</div>

<div class="container">
    <div class="form-container">
        <h1 class="u-mb20"><?= _("Performance Dashboard") ?> <span class="badge bg-info">QemuCP</span></h1>

        <!-- CPU & RAM -->
        <div class="row u-mb20" id="stats-container">
            <div class="col-md-3">
                <div class="card">
                    <div class="card-body text-center">
                        <h5 class="card-title"><?= _("CPU Usage") ?></h5>
                        <div class="display-4" id="cpu-usage">--</div>
                        <small class="text-muted"><?= _("Load average") ?>: <span id="load-avg">--</span></small>
                    </div>
                </div>
            </div>
            <div class="col-md-3">
                <div class="card">
                    <div class="card-body text-center">
                        <h5 class="card-title"><?= _("RAM Usage") ?></h5>
                        <div class="display-4" id="ram-usage">--</div>
                        <small class="text-muted"><span id="ram-used">--</span> / <span id="ram-total">--</span></small>
                    </div>
                </div>
            </div>
            <div class="col-md-3">
                <div class="card">
                    <div class="card-body text-center">
                        <h5 class="card-title"><?= _("Disk Usage") ?></h5>
                        <div class="display-4" id="disk-usage">--</div>
                        <small class="text-muted"><span id="disk-used">--</span> / <span id="disk-total">--</span></small>
                    </div>
                </div>
            </div>
            <div class="col-md-3">
                <div class="card">
                    <div class="card-body text-center">
                        <h5 class="card-title"><?= _("Uptime") ?></h5>
                        <div class="display-4" style="font-size:1.5rem" id="uptime">--</div>
                        <small class="text-muted"><?= _("Server running") ?></small>
                    </div>
                </div>
            </div>
        </div>

        <!-- Services Status -->
        <h3 class="u-mb10"><?= _("Services") ?></h3>
        <div class="table-responsive u-mb20">
            <table class="table" id="services-table">
                <thead>
                    <tr>
                        <th><?= _("Service") ?></th>
                        <th><?= _("Status") ?></th>
                        <th><?= _("Memory") ?></th>
                        <th><?= _("CPU") ?></th>
                    </tr>
                </thead>
                <tbody id="services-body">
                    <tr><td colspan="4" class="text-center"><?= _("Loading...") ?></td></tr>
                </tbody>
            </table>
        </div>

        <!-- Nginx connections -->
        <h3 class="u-mb10"><?= _("Nginx Active Connections") ?></h3>
        <div class="row u-mb20">
            <div class="col-md-4">
                <div class="card">
                    <div class="card-body text-center">
                        <h6><?= _("Active") ?></h6>
                        <div class="h3" id="nginx-active">--</div>
                    </div>
                </div>
            </div>
            <div class="col-md-4">
                <div class="card">
                    <div class="card-body text-center">
                        <h6><?= _("Waiting") ?></h6>
                        <div class="h3" id="nginx-waiting">--</div>
                    </div>
                </div>
            </div>
            <div class="col-md-4">
                <div class="card">
                    <div class="card-body text-center">
                        <h6><?= _("Requests/s") ?></h6>
                        <div class="h3" id="nginx-requests">--</div>
                    </div>
                </div>
            </div>
        </div>

        <!-- Redis stats -->
        <h3 class="u-mb10"><?= _("Redis Cache") ?></h3>
        <div class="row u-mb20">
            <div class="col-md-3">
                <div class="card">
                    <div class="card-body text-center">
                        <h6><?= _("Memory Used") ?></h6>
                        <div class="h3" id="redis-mem">--</div>
                    </div>
                </div>
            </div>
            <div class="col-md-3">
                <div class="card">
                    <div class="card-body text-center">
                        <h6><?= _("Hit Rate") ?></h6>
                        <div class="h3" id="redis-hits">--</div>
                    </div>
                </div>
            </div>
            <div class="col-md-3">
                <div class="card">
                    <div class="card-body text-center">
                        <h6><?= _("Connected Clients") ?></h6>
                        <div class="h3" id="redis-clients">--</div>
                    </div>
                </div>
            </div>
            <div class="col-md-3">
                <div class="card">
                    <div class="card-body text-center">
                        <h6><?= _("Keys") ?></h6>
                        <div class="h3" id="redis-keys">--</div>
                    </div>
                </div>
            </div>
        </div>
    </div>
</div>

<script>
function refreshStats() {
    fetch('/api/performance-stats/')
        .then(r => r.json())
        .then(data => {
            // CPU
            document.getElementById('cpu-usage').textContent = data.cpu + '%';
            document.getElementById('load-avg').textContent = data.load;

            // RAM
            document.getElementById('ram-usage').textContent = data.ram_pct + '%';
            document.getElementById('ram-used').textContent = data.ram_used;
            document.getElementById('ram-total').textContent = data.ram_total;

            // Disk
            document.getElementById('disk-usage').textContent = data.disk_pct + '%';
            document.getElementById('disk-used').textContent = data.disk_used;
            document.getElementById('disk-total').textContent = data.disk_total;

            // Uptime
            document.getElementById('uptime').textContent = data.uptime;

            // Services
            let tbody = '';
            (data.services || []).forEach(s => {
                const badge = s.active
                    ? '<span class="badge bg-success">Active</span>'
                    : '<span class="badge bg-danger">Inactive</span>';
                tbody += `<tr><td>${s.name}</td><td>${badge}</td><td>${s.mem}</td><td>${s.cpu}</td></tr>`;
            });
            document.getElementById('services-body').innerHTML = tbody || '<tr><td colspan="4">No data</td></tr>';

            // Nginx
            if (data.nginx) {
                document.getElementById('nginx-active').textContent = data.nginx.active;
                document.getElementById('nginx-waiting').textContent = data.nginx.waiting;
                document.getElementById('nginx-requests').textContent = data.nginx.rps;
            }

            // Redis
            if (data.redis) {
                document.getElementById('redis-mem').textContent = data.redis.memory;
                document.getElementById('redis-hits').textContent = data.redis.hit_rate + '%';
                document.getElementById('redis-clients').textContent = data.redis.clients;
                document.getElementById('redis-keys').textContent = data.redis.keys;
            }
        })
        .catch(e => console.error('Stats error:', e));
}

// Auto-refresh cada 10 segundos
refreshStats();
setInterval(refreshStats, 10000);
</script>
