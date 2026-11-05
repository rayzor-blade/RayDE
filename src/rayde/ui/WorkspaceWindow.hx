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
	final pendingTrust:Signal<Null<String>>;
	final approving = Signal.make(false);
	final approvalError = Signal.make("");
	final approvals = new rayde.run.Worker<{server:CompilerServer,entry:String}, {entry:String,workspace:WorkbenchProps}>((job, cancelled) -> {
		if (cancelled() || !rayde.settings.WorkspaceTrust.trusted(job.entry)) throw "The workspace approval changed. Open the project again.";
		return {entry:job.entry,workspace:describe(job.server, job.entry)};
	});
	var approvalTimer:Null<ashui.animation.AnimationScheduler.Timer>;
	var gone = false;
	var started = false;

	public function new(props:WorkspaceWindowProps) {
		current = Signal.make(props.initial);
		pendingTrust = Signal.make(props.initial.pendingTrust);
		super(props);
	}

	/** The initial shell is inert until an existing project's authors have been approved. */
	public static function prepare(server:CompilerServer, ?entry:String):WorkbenchProps {
		if (entry == null || rayde.settings.WorkspaceTrust.trusted(entry)) return describe(server, entry);
		var welcome = describe(server);
		welcome.pendingTrust = Fs.fullPath(entry);
		return welcome;
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
		if (pendingTrust.get() != null || approving.get()) cancelTrust();
		if (!rayde.settings.WorkspaceTrust.trusted(entry)) { approvalError.set(""); pendingTrust.set(Fs.fullPath(entry)); return; }
		var next = describe(props.server, entry);
		activate(entry, next);
	}

	function activate(entry:String, next:WorkbenchProps):Void {
		rayde.settings.RecentProjects.remember(entry);
		current.set(next);
		rayde.workspace.PageHost.selected(entry);
		if (props.onWorkspaceChanged != null) props.onWorkspaceChanged(Fs.fullPath(entry));
	}

	function trust(entry:String):Void {
		if (pendingTrust.get() != entry || approving.get()) return;
		rayde.settings.WorkspaceTrust.remember(entry);
		approvalError.set(""); approving.set(true);
		approvals.submit("open", {entry:entry,server:props.server});
		approvalTimer = ashui.animation.AnimationScheduler.main.after(.016, pollApproval);
	}

	function cancelTrust():Void {
		approvals.cancel("open"); pendingTrust.set(null); approving.set(false); approvalError.set("");
		if (approvalTimer != null) { approvalTimer.cancel(); approvalTimer = null; }
	}

	function pollApproval():Void {
		approvalTimer = null; if (gone) return;
		for (result in approvals.poll()) {
			approving.set(false);
			if (result.error != null) approvalError.set(result.error);
			else {
				var entry = pendingTrust.get();
				if (entry != null && entry == result.value.entry) try { activate(entry, result.value.workspace); pendingTrust.set(null); } catch (error:Dynamic) approvalError.set(Std.string(error));
			}
		}
		if (approving.get()) approvalTimer = ashui.animation.AnimationScheduler.main.after(.02, pollApproval);
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
		Owner.onCleanup(() -> {
			gone = true; approvals.dispose();
			if (approvalTimer != null) approvalTimer.cancel();
			if (content != null) content.dispose();
		});
		holder.appendChild(<for {entry in [pendingTrust.get()]}><if {entry != null}><workspace-trust-dialog entry={entry} busy={approving} error={approvalError} cancel={cancelTrust} trust={() -> trust(entry)}/></if></for>);
		return holder;
	}

	function mount(workspace:WorkbenchProps):Element {
		applyAppearance(workspace);
		var chrome = props.chrome ?? new WindowChrome();
		chrome.title("RayDE" + (workspace.empty == true ? "" : " · " + workspace.name));
		bench = new Workbench({display:workspace.display, name:workspace.name, runtime:workspace.runtime,
			extension:workspace.extension, theme:workspace.theme, empty:workspace.empty, chrome:chrome, onWorkspace:open,
			#if (wasm || rayde_page)
			onNewWindow:null, onNewWorkspace:null
			#else
			onNewWindow:props.openWindow == null ? null : () -> props.openWindow(null),
			onNewWorkspace:props.openWindow == null || workspace.empty == true ? null : path -> props.openWindow(path)
			#end
		});
		bench.openProject();
		#if wasm
		var demo = rayde.workspace.PageHost.bridge != null && rayde.workspace.PageHost.bridge.demo;
		var embedded = rayde.workspace.PageHost.bridge != null && rayde.workspace.PageHost.bridge.embedded;
		var example = workspace.display.cwd + "/src/Main.hx";
		var board = workspace.display.cwd + "/src/ui/BoardApp.hx";
		var pocket = Fs.exists(board) && Fs.exists(workspace.display.cwd + "/extensions/pocket-tools/pocket-tools.rayext");
		if (!started && (demo || embedded && pocket) && bench.open.get().length == 0 && Fs.exists(example) && !Fs.isDirectory(example)) {
			bench.openFile(example);
			if (pocket) { bench.openFile(board); bench.editorPart.splitEditor("horizontal"); }
		}
		if (!started && (demo || embedded)) bench.collapseSidebar();
		#end
		#if wasm
		if (!started && workspace.pendingTrust == null && rayde.workspace.PageHost.bridge != null && rayde.workspace.PageHost.bridge.repositories)
			bench.projectPart.pickProject("project");
		#end
		if (!started && workspace.pendingTrust == null) {
			started = true;
			var tab = Sys.getEnv("RAYDE_PANEL");
			if (tab == "terminal") bench.toggleTerminal(); else if (tab != null && tab != "") bench.showPanel(tab);
			var section = Sys.getEnv("RAYDE_SETTINGS");
			if (section != null && section != "") bench.openSettings(section);
		}
		return bench;
	}
}
