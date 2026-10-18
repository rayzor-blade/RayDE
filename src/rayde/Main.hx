package rayde;

import ashui.app.WindowedApp;
import ashui.theme.themes.RestrainedTheme;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

/** RayDE as an application: `rayde <build.hxml>` opens that project in the workbench. */
class Main {
	static function main():Void {
		var args = Sys.args();
		if (args.length == 0) {
			Sys.println("usage: rayde <build.hxml>");
			Sys.exit(1);
		}
		ashui.theme.ThemeState.init(RestrainedTheme.bundle(), Dark);
		rayde.ui.Style.use();
		var server = new CompilerServer(), display = Display.ofHxml(server, args[0]);
		var name = haxe.io.Path.withoutDirectory(haxe.io.Path.directory(sys.FileSystem.fullPath(args[0])));
		WindowedApp.run({
			title: "RayDE · " + name,
			width: 1280,
			height: 800,
			minWidth: 800,
			minHeight: 560,
			theme: RestrainedTheme.bundle(),
			appearance: Dark
		}, () -> {
			var bench = new Workbench({display: display, name: name, runtime: "ash"});
			// RAYDE_PANEL=terminal (or problems, console) opens the bottom panel on that tab at launch, for scripted runs.
			var tab = Sys.getEnv("RAYDE_PANEL");
			if (tab == "terminal")
				bench.toggleTerminal();
			else if (tab != null && tab != "")
				bench.showPanel(tab);
			return bench;
		});
		server.stop();
	}
}
