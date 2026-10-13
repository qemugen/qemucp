<?php
// QemuCP - datos del Performance Dashboard (JSON, solo administradores).
// Usa la sesion y el login del panel (inc/main.php). Antes abria una sesion
// propia y miraba $_SESSION['role'], que el panel no define: respondia
// siempre "no autorizado".
include $_SERVER["DOCUMENT_ROOT"] . "/inc/main.php";

header("Content-Type: application/json");
header("Cache-Control: no-cache");

if (($_SESSION["userContext"] ?? "") !== "admin") {
	http_response_code(403);
	exit(json_encode(["error" => "Unauthorized"]));
}

function bytes_human($bytes) {
	$units = ["B", "KB", "MB", "GB", "TB"];
	$i = 0;
	while ($bytes >= 1024 && $i < 4) {
		$bytes /= 1024;
		$i++;
	}
	return round($bytes, 1) . " " . $units[$i];
}

$stats = [];

// CPU (carga media respecto a los nucleos)
$load = sys_getloadavg();
$cores = max(1, (int) trim((string) shell_exec("nproc 2>/dev/null")));
$stats["cpu"] = min(100, round(($load[0] / $cores) * 100, 1));
$stats["load"] = implode(", ", array_map(fn($l) => round($l, 2), $load));
$stats["cores"] = $cores;

// RAM
$meminfo = (string) @file_get_contents("/proc/meminfo");
preg_match("/MemTotal:\s+(\d+)/", $meminfo, $m);
$mem_total = (int) ($m[1] ?? 0) * 1024;
preg_match("/MemAvailable:\s+(\d+)/", $meminfo, $m);
$mem_avail = (int) ($m[1] ?? 0) * 1024;
$mem_used = $mem_total - $mem_avail;
$stats["ram_pct"] = $mem_total > 0 ? round(($mem_used / $mem_total) * 100, 1) : 0;
$stats["ram_used"] = bytes_human($mem_used);
$stats["ram_total"] = bytes_human($mem_total);

// Disco
$disk_total = (float) disk_total_space("/");
$disk_used = $disk_total - (float) disk_free_space("/");
$stats["disk_pct"] = $disk_total > 0 ? round(($disk_used / $disk_total) * 100, 1) : 0;
$stats["disk_used"] = bytes_human($disk_used);
$stats["disk_total"] = bytes_human($disk_total);

// Tiempo encendido
$uptime_secs = (float) explode(" ", (string) @file_get_contents("/proc/uptime"))[0];
$days = floor($uptime_secs / 86400);
$hours = floor(($uptime_secs % 86400) / 3600);
$mins = floor(($uptime_secs % 3600) / 60);
$stats["uptime"] = $days > 0 ? "{$days}d {$hours}h" : "{$hours}h {$mins}m";

// Servicios: los de HestiaCP (incluye todas las versiones de PHP-FPM
// instaladas), como root a traves de v-list-sys-services
exec(HESTIA_CMD . "v-list-sys-services json", $output, $return_var);
$services = $return_var === 0 ? json_decode(implode("", $output), true) : [];
unset($output);
$stats["services"] = [];
foreach (is_array($services) ? $services : [] as $name => $svc) {
	$stats["services"][] = [
		"name" => $name,
		"system" => $svc["SYSTEM"] ?? "",
		"active" => ($svc["STATE"] ?? "") === "running",
		"cpu" => ($svc["CPU"] ?? "0") . "%",
		"mem" => ($svc["MEM"] ?? "0") . " MB",
	];
}

// Redis (cache de sesiones y de WordPress)
$redis_info = is_executable("/usr/bin/redis-cli")
	? (string) shell_exec("/usr/bin/redis-cli info 2>/dev/null")
	: "";
if (str_contains($redis_info, "redis_version")) {
	preg_match("/used_memory_human:(\S+)/", $redis_info, $m);
	$hits = preg_match("/keyspace_hits:(\d+)/", $redis_info, $h) ? (int) $h[1] : 0;
	$misses = preg_match("/keyspace_misses:(\d+)/", $redis_info, $x) ? (int) $x[1] : 0;
	preg_match("/connected_clients:(\d+)/", $redis_info, $c);
	$stats["redis"] = [
		"memory" => $m[1] ?? "-",
		"clients" => (int) ($c[1] ?? 0),
		"hit_rate" => $hits + $misses > 0 ? round(($hits / ($hits + $misses)) * 100, 1) : 0,
	];
} else {
	$stats["redis"] = null;
}

echo json_encode($stats);
