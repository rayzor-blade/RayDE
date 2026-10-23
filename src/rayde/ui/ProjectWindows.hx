package rayde.ui;

#if ashui_window
import ashui.app.WindowConfig;
import ashui.app.WindowedApp;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.settings.WindowSession;

private typedef ProjectWindow = {app:WindowedApp, host:WorkspaceWindow, entry:Null<String>, closing:Bool};
private typedef PreparedWindow = {config:WindowConfig, build:Void->ashui.layout.Element, server:CompilerServer};

/** Projects share the platform loop and GPU; each owns its workspace and services. */
class ProjectWindows {
	static final live:Array<ProjectWindow> = [];
	static var restoring = false;
	static var quitting = false;

	public static function quit():Void {
		checkpoint();
		quitting = true;
		try {
			for (app in WindowedApp.windows()) app.context.run(app.quit);
		} catch (error:Dynamic) { quitting = false; throw error; }
		quitting = false;
	}

	public static function run(?entry:String):Void {
		Style.use();
		var windows = startup(entry), first = windows[0], pending = windows.length;
		restoring = true;
		function build(window:PreparedWindow):ashui.layout.Element {
			var create = window.build;
			// The startup plan outlives closed windows; release factories that capture their owners.
			window.build = null; window.config = null;
			var element = create();
			if (--pending == 0) { restoring = false; checkpoint(); }
			return element;
		}
		try WindowedApp.run(first.config, () -> {
			var root = build(first);
			for (next in windows.slice(1)) WindowedApp.open(next.config, () -> build(next));
			return root;
		}) catch (error:Dynamic) {
			restoring = false;
			for (window in windows) window.server.stop();
			throw error;
		}
	}

	public static function open(?entry:String):Void {
		var next = prepare(entry);
		WindowedApp.open(next.config, next.build);
	}

	/** Only application startup resumes windows; New Window always opens Welcome. */
	static function startup(entry:Null<String>):Array<PreparedWindow> {
		if (entry != null) return [prepare(entry)];
		var entries = WindowSession.read();
		if (entries == null) entries = rayde.settings.RecentProjects.paths().slice(0, 1);
		var windows:Array<PreparedWindow> = [];
		for (path in entries) try windows.push(prepare(path)) catch (_:Dynamic) {}
		return windows.length == 0 ? [prepare(null)] : windows;
	}

	static function checkpoint():Void {
		if (restoring) return;
		var entries = [for (window in live) if (!window.closing) window.entry];
		if (entries.length > 0) WindowSession.save(entries);
	}

	static function closing(window:ProjectWindow, applicationQuit:Bool):Void {
		if (window == null || window.closing) return;
		window.closing = true;
		if (!applicationQuit) {
			var entries = [for (other in live) if (!other.closing) other.entry];
			WindowSession.save(entries.length == 0 ? [window.entry] : entries);
		}
	}

	static function prepare(entry:Null<String>):PreparedWindow {
		var server = new CompilerServer();
		var workspace = WorkspaceWindow.describe(server, entry);
		if (entry != null) entry = sys.FileSystem.fullPath(entry);
		var appearance = rayde.settings.Appearance.read(workspace.display.cwd);
		if (entry != null)
			rayde.settings.RecentProjects.remember(entry);
		var app:WindowedApp = null,
			host:WorkspaceWindow = null,
			approved = false;
		var record:ProjectWindow = null;
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
			onClose: () -> {
				if (approved || host == null) return true;
				var applicationQuit = quitting;
				var allowed = host.bench.mayCloseWindow(() -> {
					closing(record, applicationQuit);
					approved = true;
					app.context.run(app.quit);
				});
				if (allowed) closing(record, applicationQuit);
				return allowed;
			}
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
					openWindow: open,
					onWorkspaceChanged: path -> { record.entry = path; checkpoint(); }
				});
				record = {app:app, host:host, entry:entry, closing:false};
				live.push(record);
				Owner.onCleanup(() -> live.remove(record));
				checkpoint();
				return host;
			}
		};
	}
}
#end
