package rayde;

import ashui.app.WindowedApp;
import rayde.settings.Appearance;
import rayde.ui.Theming;
import rayde.ext.Manifest;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

/** RayDE as an application: `rayde <build.hxml>` opens that Haxe project, and `rayde <name.rayext>` that extension, in the workbench. */
class Main {
	static function main():Void {
		var args = Sys.args();
		if (args.length == 0) {
			Sys.println("usage: rayde <build.hxml | name.rayext>");
			Sys.exit(1);
		}
		var root = haxe.io.Path.directory(sys.FileSystem.fullPath(args[0]));
		var extension = Manifest.isManifest(args[0]) ? Manifest.read(args[0]) : null;
		rayde.theme.Themes.scan(root);
		var appearance = Appearance.read(root);
		Theming.apply(appearance);
		rayde.ui.Style.use();
		// An extension is not built by the Haxe compiler: its display has no build file, and the server never starts.
		var server = new CompilerServer(), display = extension != null ? new Display(server, root, []) : Display.ofHxml(server, args[0]);
		var name = extension != null ? extension.name : haxe.io.Path.withoutDirectory(root);
		WindowedApp.run({
			title: "RayDE · " + name,
			width: 1280,
			height: 800,
			minWidth: 800,
			minHeight: 560,
			icon: rayde.ui.AppIcon.window(),
			// RayDE draws the title bar, the window's controls and its rounded corners itself, over what is behind it.
			decorations: false,
			// RAYDE_OPAQUE=1 fills the window instead, for a display where a transparent window misbehaves; safe either way.
			transparent: Sys.getEnv("RAYDE_OPAQUE") == null,
			theme: Theming.bundle(appearance.theme),
			appearance: Theming.windowTheme(appearance)
		}, () -> {
			var bench = new Workbench({display: display, name: name, runtime: extension != null ? "rayscript" : "ash", extension: extension, chrome: rayde.ui.WindowChrome.ofApp()});
			bench.openProject();
			// RAYDE_PANEL=terminal (or problems, console) opens the bottom panel on that tab at launch, for scripted runs.
			var tab = Sys.getEnv("RAYDE_PANEL");
			if (tab == "terminal")
				bench.toggleTerminal();
			else if (tab != null && tab != "")
				bench.showPanel(tab);
			// RAYDE_SETTINGS=appearance (or build, libraries, terminal, keys, extensions) opens the Settings page on that section.
			var section = Sys.getEnv("RAYDE_SETTINGS");
			if (section != null && section != "")
				bench.openSettings(section);
			return bench;
		});
		server.stop();
	}
}
