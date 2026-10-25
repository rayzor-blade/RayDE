package rayde.ui;

import rayde.ui.Contributions.ActivityEntry;
import ashui.components.Breadcrumb;
import ashui.components.ContextMenu;
import ashui.components.ContextMenu.ContextMenuTrigger;
import ashui.components.Button;
import ashui.components.DropdownMenu;
import ashui.components.CodeEditor;
import ashui.components.code.CodeEditorState;
import ashui.components.CodeView;
import ashui.components.Icon;
import ashui.components.Resizable;
import ashui.components.Select;
import ashui.components.Tabs;
import ashui.components.Tooltip;
import ashui.components.Toast;
import ashui.components.TreeView;
import ashui.layout.Element;
import ashui.reactive.Owner;
import ashui.reactive.Computed;
import ashui.reactive.Signal;
import ashui.input.Events.KeyEvent;
import ashui.ui.Component;
import ashui.types.Style;
import ashui.ui.Ref;
import rayde.build.HxmlFile;
import rayde.actions.CodeActions;
import rayde.actions.CodeAction;
import rayde.actions.EntryPointActions;
import rayde.ext.CodeActionProviders;
import rayde.ext.Manifest;
import rayde.ext.Manager;
import rayde.ext.Manager.ManagedExtension;
import rayde.settings.Extensions;
import rayde.ext.Manifest.ViewDecl;
import rayde.files.FileOps;
import rayde.files.FileIndex;
import rayde.history.LocalHistory;
import rayde.ext.Studio;
import rayde.keys.Chord;
import rayde.keys.KeyBindings;
import rayde.keys.Keymaps;
import rayde.lang.Display;
import rayde.lang.LanguageServers;
import rayde.lang.LanguageServers.LanguageServerStatus;
import rayde.lang.LspProtocol;
import rayde.run.LibraryManager;
import rayde.run.Runner;
import rayde.run.DiagnosticJobs;
import rayde.run.OutputJobs;
import rayde.run.AnsiOutput;
import rayde.run.AnsiOutput.AnsiSpan;
import rayde.settings.Appearance;
import rayde.settings.Store;
import rayde.settings.WorkspaceSession;
import rayde.settings.WorkspaceSession.TabSession;
import rayde.theme.JsonLocator;
import rayde.theme.ThemeFile;
import rayde.theme.ThemeStudio;
import rayde.ext.Debugger;
import rayde.term.Profiles;
import rayde.term.Profiles.Profile;
import rayde.term.Settings;
import rayde.run.Tasks;
import rayde.term.Terminal;
import rayde.ui.FileTabs;
import rayde.ui.Prompt;
import rayde.ui.NewProject;
import rayde.ui.Prompt.PromptRequest;
import rayde.ui.SettingsPage;
import rayde.ui.StudioPanels;
import rayde.ui.StudioTab;
import rayde.ui.StudioView;
import rayde.ui.ThemeStudioView;
import rayde.ui.TerminalView;
import rayde.ui.Welcome;
import rayde.ui.CommandCenter;

import rayde.ui.workbench.CodeActionsPart;
import rayde.ui.workbench.DebugPart;
import rayde.ui.workbench.DocumentsPart;
import rayde.ui.workbench.EditorMarksPart;
import rayde.ui.workbench.EditorPart;
import rayde.ui.workbench.ExplorerPart;
import rayde.ui.workbench.ExtensionsPart;
import rayde.ui.workbench.KeymapPart;
import rayde.ui.workbench.LanguagesPart;
import rayde.ui.workbench.MenusPart;
import rayde.ui.workbench.PanelsPart;
import rayde.ui.workbench.ProjectPart;
import rayde.ui.workbench.RunPart;
import rayde.ui.workbench.ShellPart;
import rayde.ui.workbench.TerminalPart;
import rayde.ui.workbench.ThemePart;
import rayde.ui.workbench.Types;

using StringTools;

typedef WorkbenchProps = {
	display:Display,
	/** The project's name, as the title bar shows it. */
	name:String,
	/** The runtime the project runs on, as its profile names it: ash or rayzor. */
	?runtime:String,
	/** The extension this project is, when it was opened from a `.rayext` and not a build file. */
	?extension:Manifest,
	/** The theme this project is, when it was opened from a `.raytheme`. */
	?theme:ThemeFile,
	/** A fresh window has no workspace, file index or workspace services. */
	?empty:Bool,
	?onWorkspace:String->Void,
	?onNewWorkspace:String->Void,
	?onNewWindow:Void->Void,
	/** The window's controls: the app's window; without one the controls act on nothing and keep their own state, as in a test. */
	?chrome:WindowChrome
};



/**
 * The IDE, laid out as VS Code is: a title bar naming the project, the side
 * panel (activity bar and Explorer) down the left at full height, beside it the
 * open files as tabs over a breadcrumb and the code editor with the Problems
 * and the Output of a run below, and a status bar.
 * Each region is a card with a gap between, each part resizable. What is open,
 * and each buffer as edited, lives here, so the panes can be rebuilt without
 * losing either. `run` keeps its own watch on a build or run; a host that
 * drives the clock itself can call `tick`.
 */
@:allow(rayde.ui.workbench)
class Workbench extends Component<WorkbenchProps> {
	/** The parts of the workbench, each in its own module. */
	public final terminalPart:TerminalPart;
	public final explorerPart:ExplorerPart;
	public final codeActionsPart:CodeActionsPart;
	public final debugPart:DebugPart;
	public final editorMarksPart:EditorMarksPart;
	public final extensionsPart:ExtensionsPart;
	public final runPart:RunPart;
	public final panelsPart:PanelsPart;
	public final menusPart:MenusPart;
	public final projectPart:ProjectPart;
	public final themePart:ThemePart;
	public final languagesPart:LanguagesPart;
	public final keymapPart:KeymapPart;
	public final shellPart:ShellPart;
	public final editorPart:EditorPart;
	public final documentsPart:DocumentsPart;

	/** The activity bar's width, and the Explorer's beside it: the side panel holds both. */
	static inline var ACTIVITY = 48.;

	static inline var EXPLORER_WIDTH = 260.;

	/** The Settings page, which a tab holds in place of a file. */
	public static inline var SETTINGS = "rayde:settings";

	/** The tab of an extension's view that is shown among the files. */
	public static inline var EXTENSION_TAB = "rayde:extension";

	/** The tab of the Theme Studio page, in a project opened from a `.raytheme`. */
	public static inline var THEME_TAB = "rayde:theme";

	/** Prefix of the id of a tab an extension presented: the id is `rayde:tab:<main file>#<root>`. */
	public static inline var TAB = "rayde:tab:";

	static function isTab(file:String):Bool
		return StringTools.startsWith(file, TAB);

	static function tabStudio(file:String):String
		return file.substring(TAB.length, file.lastIndexOf("#"));

	static function tabRoot(file:String):Int
		return Std.parseInt(file.substr(file.lastIndexOf("#") + 1));

	/** The id of the tab a view declared with the location `editor` opens in. */
	static function viewTabId(viewId:String):String
		return viewId == "main" ? EXTENSION_TAB : EXTENSION_TAB + ":" + viewId;

	static function isViewTab(file:String):Bool
		return file == EXTENSION_TAB || StringTools.startsWith(file, EXTENSION_TAB + ":");

	function containerTab(c:Container):String
		return extension != null && c.extension.id == extension.id ? viewTabId(c.view.id) : EXTENSION_TAB + ":" + c.id;

	function containerOfTab(file:String):Null<Container>
		return Lambda.find(extensionsPart.containers, c -> containerTab(c) == file);

	/** The view an editor tab of an extension shows. */
	function viewOfTab(file:String):Null<ViewDecl> {
		var c = containerOfTab(file);
		return c == null ? null : c.view;
	}

	/** A page of the workbench that is not a file: Settings, a view of the extension in a tab, or a tab an extension presented. */
	static function isVirtual(file:String):Bool
		return file == SETTINGS || file == THEME_TAB || file.startsWith(HISTORY_TAB) || file.startsWith(DIFF_TAB) || isViewTab(file) || isTab(file);

	/** The width the right side bar opens to. */
	static inline var SECONDARY_WIDTH = 320.;

	/** The most terminals one screen is split among. */
	static inline var MAX_SPLITS = 4;

	public final open = Signal.make(([] : Array<String>));

	public final active = Signal.make("");

	public final problems = Signal.make(([] : Array<Diagnostic>));

	/** The open files with edits not yet written to disk. */
	public final dirty = Signal.make(([] : Array<String>));

	/** The files opened last in this project, newest first, kept in .rayde/recent.txt beside the build file. */
	public final recent = Signal.make(([] : Array<String>));

	static var compiler:Null<String> = null;

	/** Whether the command center is open. */
	public final quickOpen = Signal.make(false);

	final centerRequest = Signal.make(({text: "", serial: 0} : CenterRequest));

	/** A line the status bar shows for a few seconds: what a command could not do. */
	final notice = Signal.make("");

	var workspaceSession:WorkspaceSession;

	var sessionReady = false;

	final restoredTabs = new Map<String, Bool>();

	static inline var DIFF_TAB = "@history-diff:";

	static inline var HISTORY_TAB = "@local-history:";

	/** What the parts of the IDE register: commands, bar items, side views and the moments they follow. */
	public final contributions = new Contributions();

	/** The build file as the form edits it, read when the Settings page opens. */
	var buildModel:Null<HxmlFile>;

	/** The section of the Settings page in view. */
	final settingsCategory = Signal.make("build");

	/** How the window looks: the theme and whether it is light or dark, kept in .rayde/settings.json. */
	var appearance:Appearance;

	/** What the title bar's controls ask of the window and show of it. */
	public var chrome(default, null):WindowChrome;

	/** The style of the window's controls now: macos, windows, gnome or kde. */
	final windowStyle = Signal.make("");

	/** haxelib's installs and removals, which go on while the Settings page is out of view. */
	var libraries:LibraryManager;

	/** The commands, which the center lists, the Settings page shows and the keys run. */
	var commandList:Array<CenterAction> = [];

	/** Bumped when the build file changes, so what is drawn from it is made again. */
	final buildRevision = Signal.make(0);

	/** The side panel's width, activity bar included. */
	final treeWidth = Signal.make(ACTIVITY + EXPLORER_WIDTH);

	final explorerShown:Computed<Bool>;

	final rowsRef = new Ref<Resizable>();

	/** Completion and signature help for Haxe editors, from the compilation server. */
	var assist:CodeAssist;

	/** The question in force over the workbench: a name to ask for, or a deletion to confirm. */
	final prompt = Signal.make((null : Null<PromptRequest>));

	/** What the side panel shows beside the activity bar: the Explorer, or the extension view with this id. */
	public final sideView = Signal.make("explorer");

	/** The right side bar's width: 0 while it is closed. */
	final secondaryWidth = Signal.make(0.);

	/** Bumped when the layout has to be made again: an extension changed where its view goes. */
	final layoutRevision = Signal.make(0);

	/** The extension this project is, as its config says now: the form changes the file, and it is read again. */
	var extension:Null<Manifest>;

	/** The Preview's width beside the code. */
	final previewWidth = Signal.make(440.);

	var pill:Element;

	public function new(props:WorkbenchProps) {
		terminalPart = new TerminalPart(this);
		explorerPart = new ExplorerPart(this);
		codeActionsPart = new CodeActionsPart(this);
		debugPart = new DebugPart(this);
		editorMarksPart = new EditorMarksPart(this);
		extensionsPart = new ExtensionsPart(this);
		runPart = new RunPart(this);
		panelsPart = new PanelsPart(this);
		menusPart = new MenusPart(this);
		projectPart = new ProjectPart(this);
		themePart = new ThemePart(this);
		languagesPart = new LanguagesPart(this);
		keymapPart = new KeymapPart(this);
		shellPart = new ShellPart(this);
		editorPart = new EditorPart(this);
		documentsPart = new DocumentsPart(this);
		if (props.empty == true) treeWidth.set(ACTIVITY);
		documentsPart.localHistory = new LocalHistory(props.display.cwd);
		documentsPart.localHistory.changed = () -> documentsPart.historyRevision.set(documentsPart.historyRevision.get() + 1);
		documentsPart.localHistory.failed = message -> ashui.animation.AnimationScheduler.main.after(.01, () -> { if (!gone) say(message); });
		explorerShown = Computed.make(() -> treeWidth.get() > ACTIVITY + 8);
		panelsPart.panelShown = Computed.make(() -> panelsPart.problemsHeight.get() > 40);
		super(props);
	}

	// The window's own handles on the workbench; what each does lives in its part.
	public function mayCloseWindow(close:Void->Void):Bool return projectPart.mayCloseWindow(close);
	public function toggleTerminal():Void terminalPart.toggleTerminal();
	public function showPanel(tab:String):Void panelsPart.showPanel(tab);

	/** Opens what a project opens with: for an extension, its main script, with its view shown where the config puts it. */
	public function openProject():Void {
		if (props.empty == true) return;
		if (sessionReady) return;
		workspaceSession = new WorkspaceSession(props.display.cwd, explorerPart.projectEntry() ?? (extension != null ? extension.file : themePart.themeStudio != null ? themePart.themeStudio.file : props.display.cwd));
		var saved = workspaceSession.read();
		if (saved != null) {
			var files = [for (entry in saved.files) sessionPath(entry)];
			files = [for (file in files) if (restorableTab(file)) file];
			if (files.indexOf(SETTINGS) >= 0) buildModel = props.display.hxml == null ? null : HxmlFile.read(props.display.hxml);
			for (file in files) if (!isVirtual(file)) restoredTabs.set(file, true);
			open.set(files);
			var selected = sessionPath(saved.active);
			active.set(files.indexOf(selected) >= 0 ? selected : files.length == 0 ? "" : files[0]);
			if (saved.layout != null && saved.active == "") active.set("");
			editorPart.groups.restore(saved.layout,files,saved.group ?? 0,sessionPath);
			sessionReady = true;
			if (active.get() != "" && !isVirtual(active.get())) { restoredTabs.remove(active.get()); languagesPart.check(active.get()); }
			if (extension != null) { extensionsPart.extensionStudio(); revealViews(true); }
			return;
		}
		sessionReady = true;
		if (themePart.themeStudio != null) {
			openFile(THEME_TAB);
			return;
		}
		var m = extension;
		if (m == null)
			return;
		var main = mainFile();
		if (main != null)
			openFile(main);
		extensionsPart.extensionStudio();
		revealViews(false);
		if (main != null)
			active.set(main);
	}

	/** Each view of an extension appears where it asked to be; of the views in the sidebar, the first is shown. A restored session has its tabs already. */
	function revealViews(restored:Bool):Void {
		var revealed = false;
		for (c in extensionsPart.containers)
			switch c.location {
				case "sidebar" if (!revealed):
					revealed = true;
					sideView.set(c.id);
					if (!explorerShown.get())
						treeWidth.set(ACTIVITY + EXPLORER_WIDTH);
				case "secondary":
					secondaryWidth.set(SECONDARY_WIDTH);
				case "panel":
					panelsPart.showPanel("ext-" + c.id);
				case "editor":
					if (!restored) openFile(containerTab(c));
				case _:
			}
	}

	function sessionPath(entry:String):String
		return entry == "" || isVirtual(entry) || haxe.io.Path.isAbsolute(entry) ? entry : haxe.io.Path.join([props.display.cwd, entry]);

	function persistableTab(file:String):Bool {
		if (file == SETTINGS || file == THEME_TAB && themePart.themeStudio != null) return true;
		if (isViewTab(file)) return containerOfTab(file) != null;
		if (isVirtual(file) || file == "") return false;
		return true;
	}

	function restorableTab(file:String):Bool
		return persistableTab(file) && (isVirtual(file) || sys.FileSystem.exists(file) && !sys.FileSystem.isDirectory(file));

	function sessionSnapshot():TabSession {
		var files = [for (file in open.get()) if (persistableTab(file)) isVirtual(file) ? file : relative(file)];
		var selected = active.get(), key = isVirtual(selected) ? selected : relative(selected);
		var groups = editorPart.groups;
		return {files:files, active:selected == "" ? "" : files.indexOf(key) >= 0 ? key : files.length == 0 ? "" : files[0],
			layout:groups.snapshot(file -> persistableTab(file) ? isVirtual(file) ? file : relative(file) : null), group:groups.all().indexOf(groups.current())};
	}

	/** Opens `file` in a tab, or brings its tab forward, and checks it. */
	public function openFile(file:String):Void {
		contributions.navigated();
		editorPart.groups.sync(open.get(),active.get());
		var previousGroup = editorPart.groups.current();
		var fresh = open.get().indexOf(file) < 0;
		if (fresh)
			open.set(open.get().concat([file]));
		active.set(file);
		editorPart.groups.sync(open.get(),file);
		if (editorPart.groups.current() != previousGroup) editorPart.focusCurrent();
		if (isVirtual(file))
			return;
		remember(file);
		languagesPart.check(file);
		if (fresh)
			emit("file.opened", {path: file});
	}

	/** Opens the Settings page in a tab, or brings it forward, on the section `category` when one is named; the build file is read as it is now. */
	public function openSettings(?category:String):Void {
		if (category != null)
			settingsCategory.set(SettingsPage.category(category).id);
		if (open.get().indexOf(SETTINGS) < 0)
			buildModel = props.display.hxml == null ? null : HxmlFile.read(props.display.hxml);
		openFile(SETTINGS);
	}

	/** Opens the Settings page on the build form. */
	public function openBuild():Void
		openSettings("build");

	function rayzorManifest():Null<String>
		return props.display.project != null && props.display.project.kind == "rayzor" ? props.display.project.file : null;

	function beforeBuildChange():Void {
		var file = rayzorManifest();
		if (file != null && dirty.get().indexOf(file) >= 0) throw "Save the changes in rayzor.toml before editing its settings.";
	}

	/** The size of the element a selector finds, for tests. */
	public function boundsOf(selector:String):Null<ashui.layout.Bounds> {
		var found = ashui.css.Css.query(tree, this.node.id, selector);
		return found.length == 0 ? null : tree.getBounds(new ashui.layout.Node(found[0]));
	}

	/** Whether the first element a selector finds has the keyboard, for tests. */
	public function hasKeyboard(selector:String):Bool {
		var found = ashui.css.Css.query(tree, this.node.id, selector), at = ashui.input.Focus.of(tree);
		return found.length > 0 && at != null && at.node.id == found[0];
	}

	/** The language layer the workbench asks, for tests that look at what it was given. */
	public function display():Display
		return props.display;

	/** The build file the form is editing; null while the form is not open. */
	public function buildFile():Null<HxmlFile>
		return buildModel;

	/** The id of the section of the Settings page in view, for tests. */
	public function settingsSection():String
		return settingsCategory.get();

	/** Whether haxelib is installing, updating or removing a library, for tests that wait for it. */
	public function librariesBusy():Bool
		return libraries.busy();

	/** What the form wrote to the build file is now the project's: the compiler reads it, the Explorer and the problems follow it. */
	public function buildChanged():Void {
		props.display.reload();
		explorerPart.dependencyReadRoots = [];
		explorerPart.dependenciesRevision.set(explorerPart.dependenciesRevision.get() + 1);
		var manifest = rayzorManifest();
		if (manifest != null && documentsPart.buffers.exists(manifest) && dirty.get().indexOf(manifest) < 0)
			documentsPart.buffers.get(manifest).set(sys.io.File.getContent(manifest));
		buildRevision.set(buildRevision.get() + 1);
		for (file in open.get())
			if (file != SETTINGS)
				languagesPart.check(file);
	}

	/** Closes `file`'s tab, keeping what was edited in it; the tab beside it comes forward. */
	public function closeFile(file:String):Void {
		var wasActive = active.get() == file;
		if (languagesPart.diagnosticJobs != null) languagesPart.diagnosticJobs.cancel(file);
		var files = open.get(), at = files.indexOf(file);
		if (at < 0)
			return;
		assist.stop(file, null);
		restoredTabs.remove(file);
		var rest = files.copy();
		rest.splice(at, 1);
		documentsPart.historyTabs.remove(file);
		var comparison=documentsPart.comparisonTabs.get(file);
		if (comparison != null) comparison.dispose();
		documentsPart.comparisonTabs.remove(file);
		if (!isVirtual(file)) documentsPart.localHistory.flush(file);
		var studio = extensionsPart.studios.get(file);
		if (studio != null && !studio.managed) {
			studio.dispose();
			extensionsPart.studios.remove(file);
			extensionsPart.activeStudio.set(null);
		}
		if (isTab(file)) {
			var owner = extensionsPart.studios.get(tabStudio(file));
			if (owner != null)
				owner.closeTab(tabRoot(file));
		}
		if (active.get() == file) {
			var neighbor = editorPart.groups.neighbor(file);
			active.set(neighbor != "" ? neighbor : rest.length == 0 ? "" : rest[at < rest.length ? at : rest.length - 1]);
		}
		open.set(rest);
		editorPart.groups.sync(rest,active.get());
		if (wasActive) editorPart.focusCurrent();
		if (!isVirtual(file))
			emit("file.closed", {path: file});
	}

	/** Tells every extension that listens for `name` that it happened; `delay` collects repeats of it into one. */
	function emit(name:String, data:Dynamic, ?delay:Float):Void
		for (s in extensionsPart.studios)
			s.hook(name, data, delay);

	/** The file a page stands for, null for the pages that are not files. */
	function realFile(file:String):Null<String>
		return file.startsWith(DIFF_TAB) && documentsPart.comparisonTabs.exists(file) ? documentsPart.comparisonTabs.get(file).file : file.startsWith(HISTORY_TAB) && documentsPart.historyTabs.exists(file) ? documentsPart.historyTabs.get(file).file : file == "" || isVirtual(file) ? null : file;

	/** Adds the tabs of an extension to the editor, and takes those it has unmounted away. */
	function syncTabs(studio:Studio, list:Array<TabView>):Void {
		var mine = TAB + studio.file + "#", ids = [for (t in list) mine + t.root];
		var before = open.get();
		var kept = [for (f in before) if (!StringTools.startsWith(f, mine) || ids.indexOf(f) >= 0) f];
		var added = [for (i in ids) if (before.indexOf(i) < 0) i];
		if (added.length > 0 || kept.length != before.length)
			open.set(kept.concat(added));
		if (added.length > 0)
			active.set(added[added.length - 1]);
		else if (before.indexOf(active.get()) >= 0 && kept.indexOf(active.get()) < 0)
			active.set(kept.length == 0 ? "" : kept[kept.length - 1]);
		editorPart.groups.sync(open.get(),active.get());
	}

	/** The title an extension gave the tab `file`. */
	function tabTitle(file:String):String {
		var studio = extensionsPart.studios.get(tabStudio(file)), root = tabRoot(file);
		var view = studio == null ? null : Lambda.find(studio.tabViews, t -> t.root == root);
		return view == null ? "Extension" : view.title;
	}

	function recentFile():String
		return haxe.io.Path.join([props.display.cwd, ".rayde", "recent.txt"]);

	function relative(path:String):String {
		var root = haxe.io.Path.addTrailingSlash(props.display.cwd);
		return path.startsWith(root) ? path.substr(root.length) : path;
	}

	function loadRecent():Void {
		var list = [];
		if (sys.FileSystem.exists(recentFile()))
			for (line in sys.io.File.getContent(recentFile()).split("\n")) {
				var path = haxe.io.Path.join([props.display.cwd, line]);
				if (line != "" && sys.FileSystem.exists(path))
					list.push(path);
			}
		recent.set(list);
	}

	/** Puts `file` first among the recent files, and keeps the list. */
	function remember(file:String):Void {
		var list = [file].concat([for (f in recent.get()) if (f != file) f]).slice(0, 6);
		recent.set(list);
		try {
			var dir = haxe.io.Path.join([props.display.cwd, ".rayde"]);
			if (!sys.FileSystem.exists(dir))
				sys.FileSystem.createDirectory(dir);
			sys.io.File.saveContent(recentFile(), [for (f in list) relative(f)].join("\n"));
		} catch (_:Dynamic) {}
	}

	static function isMarkdown(path:String):Bool
		return ["md", "markdown", "mdown", "mkd"].indexOf(haxe.io.Path.extension(path).toLowerCase()) >= 0;

	/** The file of the build's main class, when the build names one and a source folder has it; for an extension, its main script. */
	function mainFile():Null<String> {
		if (extension != null)
			return sys.FileSystem.exists(extension.mainPath()) ? extension.mainPath() : null;
		if (props.display.project != null && props.display.project.main != null && sys.FileSystem.exists(props.display.project.main)) return props.display.project.main;
		var args = props.display.args;
		for (i in 0...args.length - 1)
			if (args[i] == "--main" || args[i] == "-main" || args[i] == "-m")
				for (cp in explorerPart.classpaths()) {
					var path = haxe.io.Path.join([cp.dir, args[i + 1].split(".").join("/") + ".hx"]);
					if (sys.FileSystem.exists(path))
						return path;
				}
		return null;
	}

	/** The compiler's version, asked once. */
	function compilerVersion():String {
		if (compiler == null)
			compiler = try {
				var p = new sys.io.Process(props.display.server.haxe, ["--version"]);
				var v = StringTools.trim(p.stdout.readAll().toString());
				p.close();
				"Haxe " + v;
			} catch (_:Dynamic) "Haxe";
		return compiler;
	}

	/** Opens `file` with the cursor at `line` and `character` (from 0), scrolled into view, and gives the editor the keyboard. */
	public function goTo(file:String, line:Int, character:Int):Void {
		if (ImagePreview.isSvg(file)) editorPart.imageTextMode(file).set(true);
		openFile(file);
		if (ImagePreview.isRaster(file)) return;
		var text = documentsPart.buffer(file).get(), offset = 0, at = 0;
		while (at < line && offset < text.length) {
			var next = text.indexOf("\n", offset);
			if (next < 0)
				break;
			offset = next + 1;
			at++;
		}
		offset = Std.int(Math.min(text.length, offset + character));
		// The editor of a file just opened is made at the next flush, so ask until it exists.
		var tries = 0, apply:Void->Void = null;
		apply = () -> {
			var editor = editorOf(file);
			if (editor != null && active.get() == file) {
				editor.select(offset, offset);
				editor.focus();
			} else if (++tries < 80)
				ashui.animation.AnimationScheduler.main.after(.025, apply);
		};
		ashui.animation.AnimationScheduler.main.after(.01, apply);
	}

	/** The mounted editor of the active file; inactive tabs keep document data only. */
	public function editorFor(file:String):Null<CodeEditor>
		return editorOf(file);

	function editorOf(file:String):Null<CodeEditor> {
		var ref = editorPart.editorRefs.get(file);
		return ref == null ? null : ref.get();
	}

	function editorFind(replace = false):Void {
		contributions.navigated();
		var editor = editorOf(active.get());
		if (editor != null) editor.showFind(replace);
	}

	function editorFindNext(backward = false):Void {
		contributions.navigated();
		var editor = editorOf(active.get());
		if (editor != null) editor.findNext(backward);
	}

	/** Runs the command `id` as its key or the command center would. */
	public function runCommand(id:String):Void {
		var action = Lambda.find(commandList, a -> a.id == id);
		if (action != null)
			action.run();
	}

	/** After an edit of a Haxe file: opens the completion list or signature help when what was typed calls for it. */
	function assistInput(file:String):Void {
		var editor = StringTools.endsWith(file, ".hx") || languagesPart.languageServers.client(file) != null ? editorOf(file) : null;
		if (editor != null)
			assist.typed(file, editor, documentsPart.buffer(file).get());
	}

	/** Keeps signature help showing while the text or the caret of a Haxe file moves inside a call. */
	function assistWatch(file:String, editor:Null<CodeEditor>):Void {
		if (editor == null || (!StringTools.endsWith(file, ".hx") && languagesPart.languageServers.client(file) == null))
			return;
		new ashui.reactive.Watch(() -> {
			editor.value.get();
			editor.editing.caret.get();
			0;
		}, _ -> { if (active.get() == file) assist.moved(file, editor); }, (_, _) -> false);
	}

	/** Opens the completion list at the caret of the Haxe file in front. */
	function triggerSuggest():Void {
		var file = active.get(), editor = file != "" && !isVirtual(file) && (StringTools.endsWith(file, ".hx") || languagesPart.languageServers.client(file) != null) ? editorOf(file) : null;
		if (editor != null)
			assist.complete(file, editor, documentsPart.buffer(file).get());
	}

	/** Shows the signatures of the call the caret of the Haxe file in front is in. */
	function triggerParameterHints():Void {
		var file = active.get(), editor = file != "" && !isVirtual(file) && (StringTools.endsWith(file, ".hx") || languagesPart.languageServers.client(file) != null) ? editorOf(file) : null;
		if (editor != null)
			assist.signature(file, editor, documentsPart.buffer(file).get());
	}

	/** The text offset of the cursor in `file`'s editor, or -1 while it has none. */
	public function caret(file:String):Int {
		var editor = editorOf(file);
		return editor == null ? -1 : editor.editing.caret.get();
	}

	/** The line (from 0) the cursor of `file`'s editor is on, or -1. */
	public function caretLine(file:String):Int {
		var offset = caret(file);
		if (offset < 0)
			return -1;
		var line = 0, text = documentsPart.buffer(file).get();
		for (i in 0...Std.int(Math.min(offset, text.length)))
			if (text.charCodeAt(i) == "\n".code)
				line++;
		return line;
	}

	/** Goes to where the name under the cursor is defined, or says there is none. */
	public function goToDefinition():Void {
		var file = active.get();
		definitionAt(file, caret(file));
	}

	function definitionAt(file:String, offset:Int):Void {
		if (file == "" || offset < 0)
			return;
		var client = languagesPart.languageServers.client(file), text = documentsPart.buffer(file).get(), originCaret = caret(file);
		if (client != null) {
			if (!client.supports("definitionProvider")) return;
			languagesPart.languageServers.sync(file, text);
			client.request("textDocument/definition", LspProtocol.at(file, text, offset), result -> {
				if (gone || active.get() != file || !documentsPart.buffers.exists(file) || documentsPart.buffer(file).get() != text || caret(file) != originCaret) return;
				var found = LspProtocol.locations(result);
				if (found.length == 0) say("No definition found");
				else goTo(found[0].file, found[0].range.start.line, found[0].range.start.character);
			}, file + "#definition");
			return;
		}
		var found = try props.display.definition(file, Display.byteOffset(documentsPart.buffer(file).get(), offset), documentsPart.buffer(file).get()) catch (_:Dynamic) [];
		if (found.length == 0)
			say("No definition found");
		else
			goTo(found[0].file, found[0].range.start.line, found[0].range.start.character);
	}

	/** Opens the command center with `text` in its filter: nothing for files, ">" for commands, ":" for a line. */
	public function openCenter(text = ""):Void {
		centerRequest.set({text: text, serial: centerRequest.get().serial + 1});
		quickOpen.set(true);
	}

	/** Closes every tab but the one in front. */
	public function closeOthers():Void {
		var file = active.get();
		closeExcept(file == "" ? [] : [file]);
	}

	/** Closes the tabs with nothing unsaved; the one in front goes with them unless it has edits. */
	public function closeSaved():Void {
		var keep = [for (f in open.get()) if (dirty.get().indexOf(f) >= 0) f];
		if (keep.indexOf(active.get()) < 0)
			active.set(keep.length == 0 ? "" : keep[0]);
		closeExcept(keep);
	}

	public function closeAll():Void {
		active.set("");
		closeExcept([]);
		editorPart.groups.sync([],""); editorPart.groups.join();
	}

	/** Bulk actions use the same teardown as a tab's close button, including extension view unmounts. */
	function closeExcept(keep:Array<String>):Void {
		for (file in open.get().copy())
			if (keep.indexOf(file) < 0)
				closeFile(file);
	}

	/** Puts the path of the file in front on the clipboard, in full or from the project's folder. */
	function copyPath(relative:Bool):Void {
		var file = active.get() == SETTINGS ? settingsFile() : active.get();
		if (file == null || file == "")
			return;
		var root = haxe.io.Path.addTrailingSlash(props.display.cwd);
		ashui.input.Clipboard.setText(relative && file.startsWith(root) ? file.substr(root.length) : file);
		say(relative ? "Copied the relative path" : "Copied the path");
	}

	/** Opens the center to choose among `items`, in place of its files and commands. */
	function openPicker(placeholder:String, items:Array<CenterAction>):Void {
		centerRequest.set({text: "", serial: centerRequest.get().serial + 1, picker: {placeholder: placeholder, items: items}});
		quickOpen.set(true);
	}

	/** Moves the cursor of the file in front to `line` (from 1). */
	function goToLine(line:Int):Void {
		var file = active.get();
		if (file != "")
			goTo(file, line - 1, 0);
	}

	/** The file the Settings page in view is kept in, for copying its path. */
	function settingsFile():Null<String> {
		var root = props.display.cwd;
		return switch settingsCategory.get() {
			case "build": props.display.hxml;
			case "keys": haxe.io.Path.join([root, ".rayde", "keybindings.json"]);
			case "extensions": haxe.io.Path.join([root, ".rayde", "extensions"]);
			case _: haxe.io.Path.join([root, ".rayde", "settings.json"]);
		}
	}

	/** Shows `text` in the status bar for a few seconds. */
	function say(text:String):Void {
		notice.set(text);
		ashui.animation.AnimationScheduler.main.after(3, () -> if (notice.get() == text) notice.set(""));
	}

	/** Whether the workbench has been taken down, so a timer that was waiting changes nothing. */
	var gone = false;

	/** Extensions may read declared dependency sources; writes stay within the workspace. */
	function projectPath(path:String, reading = false):String {
		var full = haxe.io.Path.normalize(haxe.io.Path.isAbsolute(path) ? path : haxe.io.Path.join([props.display.cwd, path]));
		function physical(path:String):String {
			var tail:Array<String> = [];
			while (!sys.FileSystem.exists(path)) {
				var parent = haxe.io.Path.directory(path);
				if (parent == path || parent == "") return path;
				tail.unshift(haxe.io.Path.withoutDirectory(path)); path = parent;
			}
			return haxe.io.Path.join([sys.FileSystem.fullPath(path)].concat(tail));
		}
		var resolved = physical(full);
		function contains(root:String):Bool {
			return FileOps.inside(root, full) && FileOps.inside(physical(root), resolved);
		}
		if (!contains(props.display.cwd) && !(reading && (Lambda.exists(explorerPart.classpaths(), cp -> contains(cp.dir)) || Lambda.exists(explorerPart.dependencyReadRoots, contains))))
			throw 'Cannot ${reading ? "read" : "write"} "$full": outside workspace "${props.display.cwd}"${reading ? " and its declared dependency roots" : ""}.';
		return full;
	}

	/** Reads a project image within the preview's file-size budget. */
	function imageBytes(path:String):Null<haxe.io.Bytes> {
		var full = projectPath(path, true);
		if (!sys.FileSystem.exists(full) || sys.FileSystem.isDirectory(full)) return null;
		if (sys.FileSystem.stat(full).size > 8 * 1024 * 1024) throw "Preview images are limited to 8 MiB";
		return sys.io.File.getBytes(full);
	}

	function runtime():String {
		buildRevision.get();
		runPart.runnerRevision.get();
		return props.display.project != null && props.display.project.kind == "hxml" ? props.display.project.runtime : props.runtime == null ? "ash" : props.runtime;
	}

	function render():Element {
		extension = props.extension;
		runPart.runner = new Runner(props.display);
		languagesPart.diagnosticJobs = new DiagnosticJobs(props.display);
		languagesPart.languageServers = new LanguageServers(props.display.cwd);
		languagesPart.languageServers.onWake = () -> languagesPart.wakeLanguages();
		languagesPart.languageServers.onStatus = () -> { if (!gone) languagesPart.languageStatusRevision.set(languagesPart.languageStatusRevision.get() + 1); };
		languagesPart.languageServers.onDocumentActivity = file -> { if (!gone && file == active.get()) languagesPart.languageActivityRevision.set(languagesPart.languageActivityRevision.get() + 1); };
		languagesPart.languageServers.onProgress = () -> { if (!gone) languagesPart.languageActivityRevision.set(languagesPart.languageActivityRevision.get() + 1); };
		languagesPart.languageServers.onDiagnostics = value -> {
			var file = LspProtocol.path(value.uri);
			if (file == null) return;
			var source = documentsPart.buffers.get(file);
			languagesPart.diagnosticJobs.publish(file, source == null ? null : source.get(), value);
			languagesPart.wakeDiagnostics();
		};
		languagesPart.languageServers.onChanged = () -> {
			if (gone) return;
			languagesPart.languageRevision.set(languagesPart.languageRevision.get() + 1);
			for (file in open.get()) if (!isVirtual(file) && (file == active.get() || documentsPart.buffers.exists(file))) languagesPart.check(file);
			explorerPart.refreshExplorer();
			languagesPart.wakeLanguages();
		};
		terminalPart.terminalSettings = Settings.read(props.display.cwd);
		appearance = Appearance.read(props.display.cwd);
		chrome = props.chrome != null ? props.chrome : new WindowChrome();
		assist = new CodeAssist(props.display, languagesPart.languageServers);
		if (props.theme != null)
			themePart.themeStudio = themePart.makeThemeStudio(props.theme.file);
		windowStyle.set(WindowControls.styleFor(appearance.windowControls));
		shellPart.registerShell();
		keymapPart.bindings = KeyBindings.read(props.display.cwd, Sys.systemName() == "Mac");
		libraries = new LibraryManager(props.display.cwd);
		codeActionsPart.setupCodeActions();
		extensionsPart.startExtensions();
		extensionsPart.containers = extensionsPart.makeContainers();
		commandList = shellPart.commands();
		var receiveLanguages:ashui.layout.LayoutTree->Void = current -> {
			if (current == tree && !gone && languagesPart.languageServers.hasEvents()) languagesPart.pollLanguages();
		};
		ashui.layout.LayoutTree.flushHooks.push(receiveLanguages);
		var receiveFrame:ashui.layout.LayoutTree->Void = current -> { if (current == tree && !gone) contributions.frame(); };
		ashui.layout.LayoutTree.flushHooks.push(receiveFrame);
		Owner.onCleanup(() -> {
			for (i in 0...ashui.layout.LayoutTree.flushHooks.length) if (Reflect.compareMethods(ashui.layout.LayoutTree.flushHooks[i],receiveFrame)) {
				ashui.layout.LayoutTree.flushHooks.splice(i,1); break;
			}
		});
		Owner.onCleanup(() -> ashui.layout.LayoutTree.flushHooks.remove(receiveLanguages));
		#if ashui_window
		menusPart.installDesktopMenus();
		#end
		explorerPart.refreshFileIndex();
		keymapPart.refreshShortcuts();
		if (props.empty != true) loadRecent();
		new ashui.reactive.Watch(() -> { open.get(); active.get(); 0; }, _ -> editorPart.groups.sync(open.get(),active.get()), (_, _) -> false);
		new ashui.reactive.Watch(() -> { open.get(); dirty.get(); 0; }, _ -> documentsPart.releaseClosedDocuments(), (_, _) -> false);
		new ashui.reactive.Watch(() -> panelsPart.problemsHeight.get(), h -> if (h > 40) panelsPart.panelHeight = h);
		new ashui.reactive.Watch(() -> { open.get(); active.get(); editorPart.groups.revision.get(); 0; }, _ -> {
			if (sessionReady) workspaceSession.save(sessionSnapshot());
		}, (_, _) -> false);
		var previousActive = "";
		new ashui.reactive.Watch(() -> active.get(), file -> {
			if (previousActive != "" && previousActive != file) assist.stop(previousActive,editorOf(previousActive));
			previousActive = file;
			contributions.activeChanged(file);
			extensionsPart.activeStudio.set(extension != null ? extensionsPart.extensionStudio() : extensionsPart.studios.get(file));
			emit("active.changed", {path: realFile(file)});
		});
		new ashui.reactive.Watch(() -> { active.get(); sideView.get(); 0; }, _ -> ashui.core.Memory.collectSoon(), (_, _) -> false);
		new ashui.reactive.Watch(() -> panelsPart.panelShown.get(), shown -> panelsPart.markPanel(shown));
		new ashui.reactive.Watch(() -> panelsPart.panelShown.get() && panelsPart.bottom.get() == "console", visible -> {
			if (visible && extensionsPart.extensionOutputDirty) extensionsPart.refreshExtensionOutput();
		});
		// The controls go grey while another window is in front.
		new ashui.reactive.Watch(() -> ashui.input.WindowState.active.get(), on -> chrome.focused.set(on));
		// The terminal starts when its tab is first in view, not when RayDE does.
		new ashui.reactive.Watch(() -> {
			panelsPart.bottom.get();
			panelsPart.panelShown.get();
			0;
		}, _ -> if (panelsPart.bottom.get() == "terminal" && panelsPart.panelShown.get())
			terminalPart.ensureTerminal(), (_, _) -> false);
		Owner.onCleanup(() -> {
			gone = true;
			contributions.closing();
			if (codeActionsPart.codeActionTimer != null) codeActionsPart.codeActionTimer.cancel();
			if (codeActionsPart.codeActionPoll != null) codeActionsPart.codeActionPoll.cancel();
			codeActionsPart.codeActionTimer = null; codeActionsPart.codeActionPoll = null;
			codeActionsPart.entryActions.dispose(); codeActionsPart.codeActions.dispose();
			if (projectPart.cancelProjectDialog != null) projectPart.cancelProjectDialog();
			projectPart.cancelProjectDialog = null;
			projectPart.projectPicker.dispose();
			if (languagesPart.languagePollTimer != null) languagesPart.languagePollTimer.cancel();
			languagesPart.languagePollTimer = null;
			languagesPart.languagesScheduled = false;
			if (workspaceSession != null) workspaceSession.close(sessionReady ? sessionSnapshot() : null);
			explorerPart.fileIndex.dispose();
			for (comparison in documentsPart.comparisonTabs) comparison.dispose();
			documentsPart.comparisonTabs.clear();
			documentsPart.localHistory.dispose();
			for (syntax in editorPart.nativeSyntax) if (syntax != null) syntax.dispose();
			editorPart.nativeSyntax.clear();
			languagesPart.diagnosticJobs.dispose();
			extensionsPart.outputJobs.dispose();
			runPart.runner.stop();
			languagesPart.languageServers.dispose();
			for (s in terminalPart.sessions)
				s.terminal.close();
			// An extension's host is a process of its own, which goes with the workbench.
			extensionsPart.extensionManager.dispose();
			for (studio in extensionsPart.studios)
				studio.dispose();
			if (themePart.themeStudio != null)
				themePart.themeStudio.dispose();
		});
		new ashui.reactive.Watch(() -> {
			active.get();
			settingsCategory.get();
			explorerPart.folderStates.get();
			for (open in explorerPart.folderOpen)
				open.get();
			explorerPart.treeSelected.get();
			0;
		}, _ -> explorerPart.keepSelection(), (_, _) -> false);
		var window = <div id="rayde-window" widthPercent={1} heightPercent={1} class="flex flex-col bg-background text-text-primary relative">
			${shellPart.titleBar()}
			${menusPart.desktopMenuBar()}
			<div class="flex flex-1 min-h-0 px-2">
				<for {revision in [layoutRevision.get()]}>${shellPart.columns()}</for>
			</div>
			${shellPart.statusBar()}
			<prompt request={prompt}/>
			<if {projectPart.creatingProject.get()}><new-project opened={projectPart.creatingProject} directory={props.display.cwd} templates={projectPart.projectTemplates} onCreate={projectPart.openWorkspace}/></if>
			<for {direction in (chrome.resizable() ? EDGES : [])}>${shellPart.edge(direction)}</for>
			<command-center opened={quickOpen} request={centerRequest} anchor={pill} files={explorerPart.recentFiles} refreshFiles={explorerPart.refreshFileIndex} root={props.display.cwd} actions={commandList} tasks={runPart.taskChoices}
				onOpenFile={path -> openFile(path)} onLine={goToLine}/>
			<toaster id="rayde-toaster"/>
		</div>;
		// A window of its own, not filling the screen, has rounded corners (but Windows's) and, where the system draws no frame, an outline.
		// They are on a card inside the root, which is the whole of what the window draws and cannot be clipped.
		var root = <div id="rayde" widthPercent={1} heightPercent={1} class="flex flex-col text-text-primary" onKeyDown={keymapPart.key}>{window}</div>;
		// Keys go to the node that has the keyboard and bubble up from it, so with nothing focused no shortcut would be heard. The root
		// takes the keyboard whenever nothing else has it, which is how a window just opened, the Welcome page and a press on bare
		// space leave it.
		var keyboard = ashui.input.Interaction.of(root.node).setFocusable(true);
		var catchKeys:ashui.layout.LayoutTree->Bool = t -> {
			if (gone || t != root.tree || ashui.input.Focus.of(t) != null) return false;
			ashui.input.Focus.set(keyboard, false);
			return false;
		};
		ashui.layout.LayoutTree.layoutHooks.push(catchKeys);
		ashui.reactive.Owner.onCleanup(() -> {
			for (i in 0...ashui.layout.LayoutTree.layoutHooks.length)
				if (Reflect.compareMethods(ashui.layout.LayoutTree.layoutHooks[i], catchKeys)) { ashui.layout.LayoutTree.layoutHooks.splice(i, 1); break; }
		});
		var identity = ashui.css.Identity.of(window.tree, window.node.id);
		// A theme's own stylesheet is written under this, so it applies only while the theme is in use.
		ashui.css.Identity.of(root.tree, root.node.id).bindAttribute("data-theme", Computed.make(() -> Theming.current.get()));
		ashui.css.Identity.of(root.tree, root.node.id).bindBooleanAttribute("data-sans", Computed.make(() -> Theming.ownSans.get()));
		identity.bindBooleanAttribute("data-round", Computed.make(() -> chrome.resizable() && windowStyle.get() != "windows"));
		identity.bindBooleanAttribute("data-outline", Computed.make(() -> chrome.resizable() && windowStyle.get() != "macos"));
		return root;
	}

	/** The edges and corners that resize the window, in the order they are laid over the page. */
	static final EDGES = ["North", "South", "East", "West", "NorthEast", "NorthWest", "SouthEast", "SouthWest"];

	/** Opens and closes the bottom panel; lit while it is open. */
	function panelItem(on:Bool):Element {
		var item = <div id="rayde-panel-toggle" class="rayde-status-item action flex" onClick={_ -> panelsPart.togglePanel()}><icon document={Icons.LAYOUT_BOTTOM_LINE} class="size-3.5"/></div>;
		if (on)
			ashui.css.Identity.of(item.tree, item.node.id).setAttribute("data-on", "");
		return <tooltip label={"Toggle panel (" + (Sys.systemName() == "Mac" ? "⌘" : "Ctrl+") + "J)"} side="top">{item}</tooltip>;
	}
}
