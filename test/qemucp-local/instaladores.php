<?php
// Banco de pruebas LOCAL de los instaladores de aplicaciones (sin Composer
// ni HestiaCP). Carga todos los *Setup.php (uno roto tumba /add/webapp y la
// pestana APLICACIONES) y simula una instalacion de las versiones
// optimizadas anotando los comandos WP-CLI / PrestaShop que ejecutarian.
//
// Desde la raiz del repo, con cualquier PHP >= 8.2, p.ej. el de WebAssembly:
//   npx @php-wasm/cli test/qemucp-local/instaladores.php
// Sale con 1 si algun instalador no carga o no tiene logo.
declare(strict_types=1);

namespace Symfony\Component\Process\Exception {
	class ProcessFailedException extends \RuntimeException {}
}
namespace Symfony\Component\Process {
	class Process {}
}

namespace {
	spl_autoload_register(function ($c) {
		if (str_starts_with($c, "Hestia\\")) {
			$f = "web/src/app/" . str_replace("\\", "/", substr($c, 7)) . ".php";
			if (is_file($f)) {
				require $f;
			}
		}
	});

	class FakeApp extends Hestia\System\HestiaApp {
		public array $log = [];
		public function __construct() {}
		public function getSupportedPHPVersions(array $s): array {
			return array_values(array_intersect($s, ["8.2", "8.3"]));
		}
		public function user(): string {
			return "cliente1";
		}
		private function r(string $what, array $a) {
			$this->log[] = $what . " " . implode(" ", $a);
			return new Hestia\System\HestiaCommandResult($what, 0, "");
		}
		public function runWp(string $p, array $a): Hestia\System\HestiaCommandResult {
			return $this->r("wp(php$p)", $a);
		}
		public function runPHP(string $p, string $c, array $a): Hestia\System\HestiaCommandResult {
			return $this->r("php$p " . basename($c), $a);
		}
		public function sendPostRequest($u, array $f, array $h = [], string $r = ""): void {
			$this->r("POST", [$u, json_encode($f)]);
		}
		public function archiveExtract(string $f, string $d): void {
			$this->r("extract", [$f, $d]);
		}
		public function deleteFile(string $f): void {
			$this->r("rm", [$f]);
		}
		public function deleteDirectory(string $f): void {
			$this->r("rmdir", [$f]);
		}
	}

	$fallos = 0;
	$ok = 0;
	foreach (glob("web/src/app/WebApp/Installers/*/*Setup.php") as $f) {
		$d = basename(dirname($f));
		$c = "\\Hestia\\WebApp\\Installers\\$d\\{$d}Setup";
		try {
			$info = (new $c(new FakeApp()))->getInfo();
			$thumb = dirname($f) . "/" . $info->thumbnail;
			if (!is_file($thumb)) {
				echo "SIN LOGO $d ($info->thumbnail)\n";
				$fallos++;
			}
			$ok++;
		} catch (Throwable $e) {
			echo "ROTO $d: " . $e->getMessage() . "\n";
			$fallos++;
		}
	}
	echo "Instaladores que cargan: $ok\n";

	use Hestia\WebApp\InstallationTarget\{InstallationTarget, TargetDomain, TargetDatabase};
	foreach (["WordPressOptimized" => true, "PrestaShopOptimized" => false] as $d => $ssl) {
		$app = new FakeApp();
		$c = "\\Hestia\\WebApp\\Installers\\$d\\{$d}Setup";
		$inst = new $c($app);
		$form = $inst->getConfig("form");
		$opts = [
			"php_version" => "8.3",
			"install_directory" => "",
			"site_name" => "Mi web",
			"username" => "wpadmin",
			"password" => "x",
			"email" => "a@b.es",
			"language" => $form["language"]["value"],
			"shop_name" => "Mi tienda",
			"first_name" => "A",
			"last_name" => "B",
		];
		$t = new InstallationTarget(
			new TargetDomain("ejemplo.es", "/home/cliente1/web/ejemplo.es", "1.2.3.4", $ssl),
			new TargetDatabase("localhost", "cliente1_db", "cliente1_u", "pw", true),
		);
		$m = new ReflectionMethod($inst, "setupApplication");
		$m->invoke($inst, $t, $opts);
		echo "\n== $d (idioma por defecto: {$form["language"]["value"]}, SSL: " .
			($ssl ? "si" : "no") .
			")\n";
		foreach ($app->log as $l) {
			echo "  $l\n";
		}
	}
	exit($fallos ? 1 : 0);
}
