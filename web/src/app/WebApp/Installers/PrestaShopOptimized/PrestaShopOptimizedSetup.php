<?php

declare(strict_types=1);

/**
 * QemuCP - PrestaShop Optimizado
 *
 * Hereda el instalador oficial de PrestaShop de HestiaCP y lo deja listo para
 * una tienda en Espana: idioma, pais y zona horaria espanoles, prefijo de
 * tablas aleatorio y sin suscripcion al boletin de PrestaShop.
 *
 * (La version anterior extendia Hestia\WebApp\Installers\BaseSetup, que no
 * existe desde HestiaCP 1.10, y rompia la lista del instalador entera.
 * Ademas renombraba la carpeta admin a un nombre aleatorio sin decirselo a
 * nadie: el cliente no encontraba su panel de la tienda. Ya no se hace.)
 */

namespace Hestia\WebApp\Installers\PrestaShopOptimized;

use Hestia\System\Util;
use Hestia\WebApp\InstallationTarget\InstallationTarget;
use Hestia\WebApp\Installers\PrestaShop\PrestaShopSetup;

class PrestaShopOptimizedSetup extends PrestaShopSetup {
	protected array $info = [
		"name" => "PrestaShop Optimizado (QemuCP)",
		"group" => "ecommerce",
		// Misma version que el instalador oficial (se descarga su zip)
		"version" => "9.1.5",
		"thumbnail" => "ps-qemucp-thumb.png",
	];

	public function __construct(\Hestia\System\HestiaApp $appcontext) {
		parent::__construct($appcontext);
		$this->config["form"]["language"]["value"] = "es";
		$this->config["form"]["shop_name"]["value"] = "Mi tienda";
	}

	protected function setupApplication(InstallationTarget $target, array $options): void {
		// Quitar el instalador web del zip y descomprimir PrestaShop
		$this->appcontext->deleteFile($target->getDocRoot("/index.php"));
		$this->appcontext->deleteFile($target->getDocRoot("/Install_PrestaShop.html"));
		$this->appcontext->archiveExtract(
			$target->getDocRoot("/prestashop.zip"),
			$target->getDocRoot("/"),
		);

		$this->appcontext->runPHP($options["php_version"], $target->getDocRoot("/install/index_cli.php"), [
			"--db_server=" . $target->database->host,
			"--db_user=" . $target->database->user,
			"--db_password=" . $target->database->password,
			"--db_name=" . $target->database->name,
			"--prefix=ps_" . Util::generateString(4, false) . "_",
			"--name=" . $options["shop_name"],
			"--firstname=" . $options["first_name"],
			"--lastname=" . $options["last_name"],
			"--language=" . $options["language"],
			"--country=es",
			"--timezone=Europe/Madrid",
			"--newsletter=0",
			"--password=" . $options["password"],
			"--email=" . $options["email"],
			"--domain=" . $target->domain->domainName,
			"--ssl=" . ($target->domain->isSslEnabled ? "1" : "0"),
		]);

		// La carpeta install debe desaparecer (PrestaShop no deja entrar al
		// panel de la tienda mientras exista)
		$this->appcontext->deleteDirectory($target->getDocRoot("/install"));
		$this->appcontext->deleteFile($target->getDocRoot("/prestashop.zip"));
	}
}
