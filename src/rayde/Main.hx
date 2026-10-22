package rayde;

import ashui.app.WindowedApp;
import rayde.ui.Theming;
import rayde.lang.CompilerServer;
import rayde.ui.WorkspaceWindow;

/** Starts on Welcome, or opens a folder, project entry, extension or theme supplied on the command line. */
class Main {
	static function main():Void {
		var args = Sys.args();
		var server = new CompilerServer(), workspace = WorkspaceWindow.describe(server, args.length == 0 ? null : args[0]);
		var appearance = WorkspaceWindow.applyAppearance(workspace);
		rayde.ui.Style.use();
		if (args.length > 0) rayde.settings.RecentProjects.remember(args[0]);
		WindowedApp.run({
			title: workspace.empty == true ? "RayDE" : "RayDE · " + workspace.name,
			width: 1280,
			height: 800,
			minWidth: 800,
			minHeight: 560,
			icon: rayde.ui.AppIcon.window(),
			// RayDE draws the title bar, the window's controls and its rounded corners itself, over what is behind it.
			decorations: false,
			// RAYDE_OPAQUE=1 fills the window instead, for a display where a transparent window misbehaves; safe either way.
			transparent: Sys.getEnv("RAYDE_OPAQUE") == null,
			theme: Theming.shown(appearance),
			appearance: Theming.windowTheme(appearance)
		}, () -> {
			var app = WindowedApp.current;
			rayde.ui.GpuProgress.attach(app.device, app.tree, () -> app.frames);
			return new WorkspaceWindow({initial:workspace, server:server, chrome:rayde.ui.WindowChrome.ofApp()});
		});
		server.stop();
	}
}
