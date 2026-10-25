package rayde.ui;

import rayde.workspace.Fs;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.reactive.Owner;
import ashui.reactive.Watch;
import ashui.ui.Component;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench.WorkbenchProps;

typedef WorkspaceWindowProps = {initial:WorkbenchProps, server:CompilerServer, ?chrome:WindowChrome, ?openWindow:Null<String>->Void, ?onWorkspaceChanged:String->Void};

/** Replaces workspace owners in the existing window; each workbench releases its own services. */
class WorkspaceWindow extends Component<WorkspaceWindowProps> {
	public var bench(default, null):Workbench;
	final current:Signal<WorkbenchProps>;
	var started = false;

	public function new(props:WorkspaceWindowProps) {
		current = Signal.make(props.initial);
		super(props);
	}

	public static function describe(server:CompilerServer, ?entry:String):WorkbenchProps {
		if (entry == null) return {display:new Display(server, rayde.settings.Extensions.home(), []), name:"Welcome", runtime:"", empty:true};
		if (!Fs.exists(entry)) throw "Workspace does not exist: " + entry;
		entry = Fs.fullPath(entry);
		var folder = Fs.isDirectory(entry);
		var extension = !folder && rayde.ext.Manifest.isManifest(entry) ? rayde.ext.Manifest.read(entry) : null;
		var theme = !folder && rayde.theme.ThemeFile.isThemeFile(entry) ? rayde.theme.ThemeFile.read(entry) : null;
		var root = folder ? entry : haxe.io.Path.directory(entry);
		var display = extension != null || theme != null ? new Display(server, root, []) : Display.ofProject(server, entry);
		return {display:display, name:extension != null ? extension.name : theme != null ? theme.name : display.project.name,
			runtime:extension != null ? "rayscript" : display.project == null ? "" : display.project.runtime, extension:extension, theme:theme};
	}

	public static function applyAppearance(workspace:WorkbenchProps):rayde.settings.Appearance {
		rayde.theme.Themes.scan(workspace.display.cwd);
		var appearance = rayde.settings.Appearance.read(workspace.display.cwd);
		if (workspace.theme != null) Theming.pin(workspace.theme, appearance); else Theming.unpin(appearance);
		return appearance;
	}

	public function open(entry:String):Void {
		var next = describe(props.server, entry);
		rayde.settings.RecentProjects.remember(entry);
		current.set(next);
		if (props.onWorkspaceChanged != null) props.onWorkspaceChanged(Fs.fullPath(entry));
	}

	function render():Element {
		var holder = <div widthPercent={1} heightPercent={1} class="flex flex-col min-w-0 min-h-0"/>;
		var parent = Owner.current, content:Owner = null;
		new Watch(() -> current.get(), workspace -> {
			// Release the old services and theme before restoring the next workspace.
			if (content != null) content.dispose();
			content = new Owner(tree, parent);
			holder.appendChild(content.run(() -> mount(workspace)));
		});
		Owner.onCleanup(() -> { if (content != null) content.dispose(); });
		return holder;
	}

	function mount(workspace:WorkbenchProps):Element {
		applyAppearance(workspace);
		var chrome = props.chrome ?? new WindowChrome();
		chrome.title("RayDE" + (workspace.empty == true ? "" : " · " + workspace.name));
		bench = new Workbench({display:workspace.display, name:workspace.name, runtime:workspace.runtime,
			extension:workspace.extension, theme:workspace.theme, empty:workspace.empty, chrome:chrome, onWorkspace:open,
			onNewWindow:props.openWindow == null ? null : () -> props.openWindow(null),
			onNewWorkspace:props.openWindow == null || workspace.empty == true ? null : path -> props.openWindow(path)});
		bench.openProject();
		if (!started) {
			started = true;
			var tab = Sys.getEnv("RAYDE_PANEL");
			if (tab == "terminal") bench.toggleTerminal(); else if (tab != null && tab != "") bench.showPanel(tab);
			var section = Sys.getEnv("RAYDE_SETTINGS");
			if (section != null && section != "") bench.openSettings(section);
		}
		return bench;
	}
}
