<div class="login">
	<a href="/" class="u-block u-mb40">
		<img src="/images/logo.svg" alt="<?= htmlentities($_SESSION["APP_NAME"]) ?>" width="320" height="68">
	</a>
	<form id="login-form" method="post" action="/login/">
		<input type="hidden" name="token" value="<?= $_SESSION["token"] ?>">
		<h1 class="login-title">
			<?= sprintf(_("Welcome to %s"), htmlentities($_SESSION["APP_NAME"])) ?>
		</h1>
		<?php if (!empty($error)) { ?>
			<p class="error"><?= $error ?></p>
		<?php } ?>
		<div class="u-mb20">
			<label for="username" class="form-label"><?= _("Username") ?></label>
			<input type="text" class="form-control" name="user" id="username" autocomplete="username" required autofocus>
		</div>
		<button type="submit" class="button">
			<i class="fas fa-right-to-bracket"></i><?= _("Next") ?>
		</button>
	</form>
</div>
