package rayde.ui;

#if ashui_window
import ashui.app.WindowConfig;
import ashui.app.WindowedApp;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;

/** Projects share the platform loop and GPU; each owns its workspace and services. */
class ProjectWindows {
	public static function quit():Void
		for (app in WindowedApp.windows())
			app.context.run(app.quit);

	public static function run(?entry:String):Void {
		Style.use();
		var first = prepare(entry);
		try
			WindowedApp.run(first.config, first.build)
		catch (error:Dynamic) {
			first.server.stop();
			throw error;
		}
	}

	public static function open(?entry:String):Void {
		var next = prepare(entry);
		WindowedApp.open(next.config, next.build);
	}

	static function prepare(entry:Null<String>):{config:WindowConfig, build:Void->ashui.layout.Element, server:CompilerServer} {
		var server = new CompilerServer();
		var workspace = WorkspaceWindow.describe(server, entry);
		var appearance = rayde.settings.Appearance.read(workspace.display.cwd);
		if (entry != null)
			rayde.settings.RecentProjects.remember(entry);
		var app:WindowedApp = null,
			host:WorkspaceWindow = null,
			approved = false;
		var config:WindowConfig = {
			title: workspace.empty == true ? "RayDE" : "RayDE · " + workspace.name,
			width: 1280,
			height: 800,
			minWidth: 800,
			minHeight: 560,
			icon: AppIcon.window(),
			decorations: false,
			transparent: Sys.getEnv("RAYDE_OPAQUE") == null,
			theme: ashui.theme.themes.RestrainedTheme.bundle(),
			appearance: Theming.windowTheme(appearance),
			onClose: () -> approved || host == null || host.bench.mayCloseWindow(() -> {
				approved = true;
				app.context.run(app.quit);
			})
		};
		return {
			config: config,
			server: server,
			build: () -> {
				app = WindowedApp.current;
				Owner.onCleanup(server.stop);
				GpuProgress.attach(app.device, app.tree, () -> app.frames);
				host = new WorkspaceWindow({
					initial: workspace,
					server: server,
					chrome: WindowChrome.ofApp(),
					openWindow: open
				});
				return host;
			}
		};
	}
}
#end
