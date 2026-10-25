package rayde;

/** Starts a command-line workspace or resumes the desktop window session. */
class Main {
	static function main():Void {
		var args = Sys.args();
		if (args.length == 1 && args[0] == "--check-install") {
			checkInstall();
			return;
		}
		#if (wasm || rayde_page)
		// In a page there is no disk and no argument: host storage and the session, or a sample, stand in.
		try rayde.ui.ProjectWindows.run(rayde.workspace.PageHost.install())
		catch (e:haxe.Exception) {
			// The page shows only that the program stopped; say why in its log.
			Sys.println("RayDE stopped: " + e.message + "\n" + haxe.CallStack.toString(e.stack));
			throw e;
		}
		#else
		rayde.ui.ProjectWindows.run(args.length == 0 ? null : args[0]);
		#end
	}

	/** Exercises the packaged runtime and extension VM without opening a window. */
	static function checkInstall():Void {
		var ids = [
			for (entry in rayde.settings.Extensions.list("", rayde.settings.Extensions.builtins(), "")) if (entry.problem == null) entry.id
		];
		for (id in ["git", "markdown", "rayzor"])
			if (ids.indexOf(id) < 0)
				throw 'Missing built-in extension: $id';
		var server = rayde.lang.RayzorBinary.find();
		if (server == null || rayde.lang.RayzorBinary.standardLibrary(server) == null)
			throw "Missing Rayzor or its standard library";
		var host = new rayde.ext.ExtensionHost();
		host.start();
		var ready = false, end = haxe.Timer.stamp() + 15;
		try {
			while (!ready && haxe.Timer.stamp() < end) {
				for (message in host.poll())
					if (message.t == "ready")
						ready = true;
				if (!ready)
					Sys.sleep(.01);
			}
		} catch (error:Dynamic) {
			host.stop();
			throw error;
		}
		host.stop();
		if (!ready)
			throw "Packaged extension VM did not become ready";
		Sys.println("RayDE installation check passed");
	}
}
