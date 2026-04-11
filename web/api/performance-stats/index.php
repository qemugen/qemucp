<?php
// QemuCP - Performance Stats API
// Solo accesible para admins autenticados

session_start();
if (empty($_SESSION['user']) || $_SESSION['role'] !== 'admin') {
    http_response_code(403);
    exit(json_encode(['error' => 'Unauthorized']));
}

header('Content-Type: application/json');
header('Cache-Control: no-cache');

function shell($cmd) {
    return trim(shell_exec($cmd . ' 2>/dev/null') ?? '');
}

function bytes_human($bytes) {
    $units = ['B','KB','MB','GB','TB'];
    $i = 0;
    while ($bytes >= 1024 && $i < 4) { $bytes /= 1024; $i++; }
    return round($bytes, 1) . $units[$i];
}

$stats = [];

// CPU
$load = sys_getloadavg();
$cores = (int)shell('nproc');
$cpu_pct = $cores > 0 ? round($load[0] / $cores * 100, 1) : 0;
$stats['cpu'] = min(100, $cpu_pct);
$stats['load'] = implode(', ', array_map(fn($l) => round($l, 2), $load));
$stats['cores'] = $cores;

// RAM
$meminfo = file_get_contents('/proc/meminfo');
preg_match('/MemTotal:\s+(\d+)/', $meminfo, $m);  $mem_total = (int)($m[1] ?? 0) * 1024;
preg_match('/MemAvailable:\s+(\d+)/', $meminfo, $m); $mem_avail = (int)($m[1] ?? 0) * 1024;
$mem_used = $mem_total - $mem_avail;
$stats['ram_pct']   = $mem_total > 0 ? round($mem_used / $mem_total * 100, 1) : 0;
$stats['ram_used']  = bytes_human($mem_used);
$stats['ram_total'] = bytes_human($mem_total);

// Disk
$disk_total = disk_total_space('/');
$disk_free  = disk_free_space('/');
$disk_used  = $disk_total - $disk_free;
$stats['disk_pct']   = $disk_total > 0 ? round($disk_used / $disk_total * 100, 1) : 0;
$stats['disk_used']  = bytes_human($disk_used);
$stats['disk_total'] = bytes_human($disk_total);

// Uptime
$uptime_secs = (float)explode(' ', file_get_contents('/proc/uptime'))[0];
$days  = floor($uptime_secs / 86400);
$hours = floor(($uptime_secs % 86400) / 3600);
$mins  = floor(($uptime_secs % 3600) / 60);
$stats['uptime'] = $days > 0 ? "{$days}d {$hours}h" : "{$hours}h {$mins}m";

// Services
$services = ['nginx', 'apache2', 'mysql', 'redis-server', 'fail2ban', 'php8.3-fpm'];
$stats['services'] = [];
foreach ($services as $svc) {
    $active = shell("systemctl is-active $svc") === 'active';
    $pid    = $active ? shell("systemctl show -p MainPID --value $svc") : null;
    $mem    = ($pid && $pid > 0) ? shell("ps -o rss= -p $pid | awk '{printf \"%.0fMB\", \$1/1024}'") : '-';
    $cpu    = ($pid && $pid > 0) ? shell("ps -o %cpu= -p $pid") . '%' : '-';
    $stats['services'][] = [
        'name'   => $svc,
        'active' => $active,
        'mem'    => $mem ?: '-',
        'cpu'    => $cpu ?: '-',
    ];
}

// Nginx connections
$nginx_status = shell('curl -s http://127.0.0.1/nginx_status 2>/dev/null');
if ($nginx_status) {
    preg_match('/Active connections:\s*(\d+)/', $nginx_status, $m);
    $stats['nginx']['active'] = $m[1] ?? 0;
    preg_match('/Waiting:\s*(\d+)/', $nginx_status, $m);
    $stats['nginx']['waiting'] = $m[1] ?? 0;
    preg_match('/(\d+)\s+(\d+)\s+(\d+)/', $nginx_status, $m);
    $stats['nginx']['rps'] = $m[3] ?? 0;
} else {
    $stats['nginx'] = ['active' => 'N/A', 'waiting' => 'N/A', 'rps' => 'N/A'];
}

// Redis stats
$redis_info = shell('redis-cli info 2>/dev/null');
if ($redis_info) {
    preg_match('/used_memory_human:(\S+)/', $redis_info, $m);
    $stats['redis']['memory'] = $m[1] ?? 'N/A';
    preg_match('/connected_clients:(\d+)/', $redis_info, $m);
    $stats['redis']['clients'] = $m[1] ?? 0;
    preg_match('/keyspace_hits:(\d+)/', $redis_info, $m);    $hits = (int)($m[1] ?? 0);
    preg_match('/keyspace_misses:(\d+)/', $redis_info, $m);  $misses = (int)($m[1] ?? 0);
    $total = $hits + $misses;
    $stats['redis']['hit_rate'] = $total > 0 ? round($hits / $total * 100, 1) : 0;
    $db_info = shell('redis-cli dbsize 2>/dev/null');
    $stats['redis']['keys'] = $db_info ?: 0;
} else {
    $stats['redis'] = ['memory' => 'N/A', 'clients' => 0, 'hit_rate' => 0, 'keys' => 0];
}

echo json_encode($stats);
