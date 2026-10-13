<?php

declare(strict_types=1);

/**
 * QemuCP - WordPress Optimizado
 *
 * Hereda el instalador oficial de WordPress de HestiaCP (descarga, base de
 * datos, wp-config y alta con WP-CLI) y anade los ajustes de QemuCP:
 * espanol por defecto, seguridad en wp-config, cache de objetos en Redis,
 * enlaces amigables, sin plugins de ejemplo y hora de Madrid.
 *
 * Todo pasa por $this->appcontext->runWp(), que ejecuta WP-CLI como el
 * usuario a traves de bin/v-run-cli-cmd: el panel corre como hestiaweb y no
 * puede escribir en /home/USUARIO ni ejecutar wp directamente.
 * (La version anterior extendia Hestia\WebApp\Installers\BaseSetup, que no
 * existe desde HestiaCP 1.10, y rompia la lista del instalador entera.)
 */

namespace Hestia\WebApp\Installers\WordPressOptimized;

use Hestia\WebApp\InstallationTarget\InstallationTarget;
use Hestia\WebApp\Installers\WordPress\WordPressSetup;
use RuntimeException;

class WordPressOptimizedSetup extends WordPressSetup {
	protected array $info = [
		"name" => "WordPress Optimizado (QemuCP)",
		"group" => "cms",
		"version" => "latest",
		"thumbnail" => "wp-qemucp-thumb.png",
	];

	public function __construct(\Hestia\System\HestiaApp $appcontext) {
		parent::__construct($appcontext);
		// Mismo formulario que el oficial, en espanol por defecto
		$this->config["form"]["language"]["value"] = "es_ES";
		$this->config["form"]["site_name"]["value"] = "Mi web";
	}

	protected function setupApplication(InstallationTarget $target, array $options = null): void {
		parent::setupApplication($target, $options);

		$php = $options["php_version"];
		$path = "--path=" . $target->getDocRoot();

		// Seguridad y rendimiento en wp-config.php
		$constants = [
			"DISALLOW_FILE_EDIT" => "true",
			"WP_POST_REVISIONS" => "5",
			"AUTOSAVE_INTERVAL" => "120",
			"EMPTY_TRASH_DAYS" => "7",
			"WP_MEMORY_LIMIT" => "'256M'",
			"WP_MAX_MEMORY_LIMIT" => "'512M'",
			"WP_REDIS_HOST" => "'127.0.0.1'",
			"WP_REDIS_PORT" => "6379",
			"WP_REDIS_DATABASE" => "2",
			"WP_REDIS_TIMEOUT" => "1",
			"WP_REDIS_READ_TIMEOUT" => "1",
		];
		// Solo con SSL: sin certificado dejaria el escritorio inaccesible
		if ($target->domain->isSslEnabled) {
			$constants["FORCE_SSL_ADMIN"] = "true";
		}
		foreach ($constants as $name => $value) {
			$this->tryWp($php, ["config", "set", $name, $value, "--raw", $path]);
		}

		// Limpieza y ajustes. Si algo falla (sin red, sin Redis...) la web
		// queda instalada igualmente: son mejoras, no requisitos.
		$this->tryWp($php, ["plugin", "delete", "hello", "akismet", $path]);
		$this->tryWp($php, ["plugin", "install", "redis-cache", "--activate", $path]);
		$this->tryWp($php, ["redis", "enable", $path]);
		$this->tryWp($php, ["rewrite", "structure", "/%postname%/", $path]);
		$this->tryWp($php, ["rewrite", "flush", $path]);
		$this->tryWp($php, ["option", "update", "timezone_string", "Europe/Madrid", $path]);
		$this->tryWp($php, ["option", "update", "default_comment_status", "closed", $path]);
	}

	private function tryWp(string $phpVersion, array $arguments): void {
		try {
			$this->appcontext->runWp($phpVersion, $arguments);
		} catch (RuntimeException $e) {
			trigger_error("QemuCP WordPress Optimizado: " . $e->getMessage());
		}
	}
}
