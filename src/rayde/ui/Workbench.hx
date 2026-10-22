package rayde.ui;

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
import rayde.ui.Prompt.PromptRequest;
import rayde.ui.SettingsPage;
import rayde.ui.StudioPanels;
import rayde.ui.StudioTab;
import rayde.ui.StudioView;
import rayde.ui.ThemeStudioView;
import rayde.ui.TerminalView;
import rayde.ui.Welcome;
import rayde.ui.CommandCenter;

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
	/** The window's controls: the app's window; without one the controls act on nothing and keep their own state, as in a test. */
	?chrome:WindowChrome
};

/** A part of the layout an extension view takes: its icon in the activity bar, and where its view is drawn. */
private typedef Container = {id:String, title:String, icon:ashui.svg.SvgDocument, location:String, view:ViewDecl, extension:Manifest};

/** A terminal that is running, and the profile it was started from. */
private typedef Session = {id:Int, group:Int, terminal:Terminal, profile:Profile};

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
class Workbench extends Component<WorkbenchProps> {
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
		return Lambda.find(containers, c -> containerTab(c) == file);

	/** The view an editor tab of an extension shows. */
	function viewOfTab(file:String):Null<ViewDecl> {
		var c = containerOfTab(file);
		return c == null ? null : c.view;
	}

	/** A page of the workbench that is not a file: Settings, a view of the extension in a tab, or a tab an extension presented. */
	static function isVirtual(file:String):Bool
		return file == SETTINGS || file == THEME_TAB || file.startsWith(HISTORY_TAB) || isViewTab(file) || isTab(file);

	/** The width the right side bar opens to. */
	static inline var SECONDARY_WIDTH = 320.;

	/** The most terminals one screen is split among. */
	static inline var MAX_SPLITS = 4;

	public final open = Signal.make(([] : Array<String>));
	public final active = Signal.make("");

	/**
	 * What the Explorer's tree shows selected, which the tree writes when a row is
	 * clicked. It is not `active`, which only a file may be: it comes back to the
	 * file in front after a click on a folder, and rests on the top-most closed
	 * folder above that file while one is closed.
	 */
	public final treeSelected = Signal.make("");

	/** Whether each folder of the Explorer is open, kept when the tree is built again. */
	final explorerFilesSize = Signal.make(Math.NaN);
	final explorerSections = new Map<String, ExplorerSection>();
	final dependenciesRevision = Signal.make(0);

	final folderOpen = new Map<String, Signal<Bool>>();

	/** Bumped when a folder first has an open state, so the selection looks at it. */
	final folderStates = Signal.make(0);
	public final problems = Signal.make(([] : Array<Diagnostic>));

	/** The open files with edits not yet written to disk. */
	public final dirty = Signal.make(([] : Array<String>));

	/** The files opened last in this project, newest first, kept in .rayde/recent.txt beside the build file. */
	public final recent = Signal.make(([] : Array<String>));

	static var compiler:Null<String> = null;

	/** Whether the command center is open. */
	public final quickOpen = Signal.make(false);

	final fileIndex = new FileIndex();
	final fileIndexRevision = Signal.make(0);
	var fileIndexScheduled = false;

	final centerRequest = Signal.make(({text: "", serial: 0} : CenterRequest));

	/** A line the status bar shows for a few seconds: what a command could not do. */
	final notice = Signal.make("");

	final localHistory:LocalHistory;
	var workspaceSession:WorkspaceSession;
	var sessionReady = false;
	final restoredTabs = new Map<String, Bool>();
	final historyRevision = Signal.make(0);
	final historyPending = new Map<String, Bool>();
	final historyTabs = new Map<String, {file:String, revision:Int, text:String}>();
	static inline var HISTORY_TAB = "@local-history:";

	final buffers = new Map<String, Signal<String>>();
	final imageViews = new Map<String, ImagePreview.ImageViewState>();
	final imageTextModes = new Map<String, Signal<Bool>>();
	final documents = new Map<String, CodeEditorState>();
	final nativeSyntax = new Map<String, Null<TextMateSyntax>>();
	final editorRefs = new Map<String, Ref<CodeEditor>>();
	final menuRef = new Ref<DropdownMenu>();

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

	/** Which key does which command, with the changes kept in .rayde/keybindings.json. */
	var bindings:KeyBindings;

	/** haxelib's installs and removals, which go on while the Settings page is out of view. */
	var libraries:LibraryManager;

	/** Changes when a key does, so the Settings page draws the keys again. */
	final bindingsRevision = Signal.make(0);

	/** The commands whose keys the terminal leaves to the workbench while it has the keyboard; any other key is the program's. */
	static final terminalKeepsOut = ["terminal", "newterminal", "splitterminal", "panel", "quickopen", "commands", "settings"];

	/** The commands, which the center lists, the Settings page shows and the keys run. */
	var commandList:Array<CenterAction> = [];

	/** Bumped when the build file changes, so what is drawn from it is made again. */
	final buildRevision = Signal.make(0);
	/** The side panel's width, activity bar included. */
	final treeWidth = Signal.make(ACTIVITY + EXPLORER_WIDTH);
	final explorerShown:Computed<Bool>;
	/** The bottom panel's height: 0 while it is closed, which is how it starts. */
	final problemsHeight = Signal.make(0.);

	/** Its height when it was last open, which opening it again goes back to. */
	var panelHeight = 190.;

	final panelShown:Computed<Bool>;
	final rowsRef = new Ref<Resizable>();

	/** The program the terminal runs, the user's login shell unless a test names one. */
	public var terminalProgram:Null<String>;

	public var terminalArgs:Null<Array<String>>;

	var sessions:Array<Session> = [];
	var activeSession = -1;
	var nextSession = 1;
	var nextGroup = 1;

	/** What the terminal is set to, read from the project's .rayde/terminal.json. */
	var terminalSettings:Settings;

	/** Completion and signature help for Haxe editors, from the compilation server. */
	var assist:CodeAssist;

	/** Changes when a terminal setting does, for the views that draw by it. */
	final settingsRevision = Signal.make(0);

	/** The terminal in front, by id, for the list beside the screens. */
	final terminalActive = Signal.make(-1);

	final views = new Map<Int, Ref<TerminalView>>();

	/** Set while a new terminal is being made on purpose, so showing the panel does not also start one. */
	var starting = false;

	final terminalGeneration = Signal.make(0);
	final terminalView = new Ref<TerminalView>();
	final profilesMenu = new Ref<DropdownMenu>();

	/** The question in force over the workbench: a name to ask for, or a deletion to confirm. */
	final prompt = Signal.make((null : Null<PromptRequest>));

	final explorerMenu = new Ref<ContextMenu>();

	/** Changes when something is cut or copied, so the menu's Paste is enabled or not. */
	final clipboardRevision = Signal.make(0);

	/** The path the Explorer's menu is open on: a file or folder, or the project's folder for the empty part of the tree. */
	final menuTarget = Signal.make("");

	/** What the side panel shows beside the activity bar: the Explorer, or the extension view with this id. */
	public final sideView = Signal.make("explorer");

	/** The right side bar's width: 0 while it is closed. */
	final secondaryWidth = Signal.make(0.);

	/** Bumped when the layout has to be made again: an extension changed where its view goes. */
	final layoutRevision = Signal.make(0);

	/** The views the extension of this project has put in the layout. */
	var containers:Array<Container> = [];

	/** The extension this project is, as its config says now: the form changes the file, and it is read again. */
	var extension:Null<Manifest>;
	public var extensionManager(default, null):Manager;
	final extensionRevision = Signal.make(0);
	final outputChannel = Signal.make("build");
	var supervisionScheduled = false;
	final extensionOutputKinds = Signal.make(new Array<String>());
	final outputStyleRevision = Signal.make(0);
	final outputSpans = new Map<String, Array<Null<Array<AnsiSpan>>>>();
	final extensionOutputView = new Ref<CodeView>();
	final outputJobs = new OutputJobs();
	var outputScheduled = false;
	var outputRevealChannel:Null<String>;
	var extensionOutputDirty = true;
	final outputKinds = new Map<String, Array<String>>();
	final outputStates = new Map<String, CodeEditorState>();
	final buildOutputSyntax = new OutputHighlighter();
	final outputSyntax = new Map<String, OutputHighlighter>();

	/** The theme being written, when this project is one: reads the editor's text and puts the theme on the window. */
	var themeStudio:Null<ThemeStudio>;

	/** The extensions open in the Studio, by their main file, and the one of the file in front, if it is one. */
	final studios = new Map<String, Studio>();

	final activeStudio = Signal.make((null : Null<Studio>));

	/** The Preview's width beside the code. */
	final previewWidth = Signal.make(440.);

	/** The tab shown below the editor: problems, console (which the panel calls Output), terminal or extension. */
	public final bottom = Signal.make("problems");

	/** What the build and the program have printed, and where the run is: idle, building, running, finished or failed. */
	final consoleText = Signal.make("");
	var diagnosticJobs:DiagnosticJobs;
	public var languageServers(default, null):LanguageServers;
	var problemScrollY = 0.;
	var problemScrollCount = 0;
	final languageStatusRevision = Signal.make(0);
	final languageActivityRevision = Signal.make(0);
	final languageRevision = Signal.make(0);
	var languagesScheduled = false;
	var languagePollTimer:Null<ashui.animation.AnimationScheduler.Timer>;
	var diagnosticsScheduled = false;

	final runState = Signal.make("idle");
	public var runner(default, null):Null<Runner>;
	var seen = -1;
	var pill:Element;
	var lastBuild:Null<Array<Diagnostic>>;

	public function new(props:WorkbenchProps) {
		localHistory = new LocalHistory(props.display.cwd);
		localHistory.changed = () -> historyRevision.set(historyRevision.get() + 1);
		localHistory.failed = message -> ashui.animation.AnimationScheduler.main.after(.01, () -> { if (!gone) say(message); });
		explorerShown = Computed.make(() -> treeWidth.get() > ACTIVITY + 8);
		panelShown = Computed.make(() -> problemsHeight.get() > 40);
		super(props);
	}

	/** Opens what a project opens with: for an extension, its main script, with its view shown where the config puts it. */
	public function openProject():Void {
		if (sessionReady) return;
		workspaceSession = new WorkspaceSession(props.display.cwd, projectEntry() ?? (extension != null ? extension.file : themeStudio != null ? themeStudio.file : props.display.cwd));
		var saved = workspaceSession.read();
		if (saved != null) {
			var files = [for (entry in saved.files) sessionPath(entry)];
			files = [for (file in files) if (restorableTab(file)) file];
			if (files.indexOf(SETTINGS) >= 0) buildModel = props.display.hxml == null ? null : HxmlFile.read(props.display.hxml);
			for (file in files) if (!isVirtual(file)) restoredTabs.set(file, true);
			open.set(files);
			var selected = sessionPath(saved.active);
			active.set(files.indexOf(selected) >= 0 ? selected : files.length == 0 ? "" : files[0]);
			sessionReady = true;
			if (active.get() != "" && !isVirtual(active.get())) { restoredTabs.remove(active.get()); check(active.get()); }
			return;
		}
		sessionReady = true;
		if (themeStudio != null) {
			openFile(THEME_TAB);
			return;
		}
		var m = extension;
		if (m == null)
			return;
		var main = mainFile();
		if (main != null)
			openFile(main);
		extensionStudio();
		// Each view appears where it asked to be; of the views in the sidebar, the first is shown.
		var revealed = false;
		for (c in containers)
			switch c.location {
				case "sidebar" if (!revealed):
					revealed = true;
					sideView.set(c.id);
					if (!explorerShown.get())
						treeWidth.set(ACTIVITY + EXPLORER_WIDTH);
				case "secondary":
					secondaryWidth.set(SECONDARY_WIDTH);
				case "panel":
					showPanel("ext-" + c.id);
				case "editor":
					openFile(containerTab(c));
				case _:
			}
		if (main != null)
			active.set(main);
	}

	function sessionPath(entry:String):String
		return entry == "" || isVirtual(entry) || haxe.io.Path.isAbsolute(entry) ? entry : haxe.io.Path.join([props.display.cwd, entry]);

	function persistableTab(file:String):Bool {
		if (file == SETTINGS || file == THEME_TAB && themeStudio != null) return true;
		if (isViewTab(file)) return containerOfTab(file) != null;
		if (isVirtual(file) || file == "") return false;
		return true;
	}

	function restorableTab(file:String):Bool
		return persistableTab(file) && (isVirtual(file) || sys.FileSystem.exists(file) && !sys.FileSystem.isDirectory(file));

	function sessionSnapshot():TabSession {
		var files = [for (file in open.get()) if (persistableTab(file)) isVirtual(file) ? file : relative(file)];
		var selected = active.get(), key = isVirtual(selected) ? selected : relative(selected);
		return {files:files, active:files.indexOf(key) >= 0 ? key : files.length == 0 ? "" : files[0]};
	}

	/** Opens `file` in a tab, or brings its tab forward, and checks it. */
	public function openFile(file:String):Void {
		var fresh = open.get().indexOf(file) < 0;
		if (fresh)
			open.set(open.get().concat([file]));
		active.set(file);
		if (isVirtual(file))
			return;
		remember(file);
		check(file);
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
		buildRevision.set(buildRevision.get() + 1);
		for (file in open.get())
			if (file != SETTINGS)
				check(file);
	}

	/** Closes `file`'s tab, keeping what was edited in it; the tab beside it comes forward. */
	public function closeFile(file:String):Void {
		if (diagnosticJobs != null) diagnosticJobs.cancel(file);
		var files = open.get(), at = files.indexOf(file);
		if (at < 0)
			return;
		assist.stop(file, null);
		restoredTabs.remove(file);
		var rest = files.copy();
		rest.splice(at, 1);
		historyTabs.remove(file);
		if (!isVirtual(file)) localHistory.flush(file);
		var studio = studios.get(file);
		if (studio != null && !studio.managed) {
			studio.dispose();
			studios.remove(file);
			activeStudio.set(null);
		}
		if (isTab(file)) {
			var owner = studios.get(tabStudio(file));
			if (owner != null)
				owner.closeTab(tabRoot(file));
		}
		if (active.get() == file)
			active.set(rest.length == 0 ? "" : rest[at < rest.length ? at : rest.length - 1]);
		open.set(rest);
		if (!isVirtual(file))
			emit("file.closed", {path: file});
	}

	/** Tells every extension that listens for `name` that it happened; `delay` collects repeats of it into one. */
	function emit(name:String, data:Dynamic, ?delay:Float):Void
		for (s in studios)
			s.hook(name, data, delay);

	/** The file a page stands for, null for the pages that are not files. */
	function realFile(file:String):Null<String>
		return file.startsWith(HISTORY_TAB) && historyTabs.exists(file) ? historyTabs.get(file).file : file == "" || isVirtual(file) ? null : file;

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
	}

	/** The title an extension gave the tab `file`. */
	function tabTitle(file:String):String {
		var studio = studios.get(tabStudio(file)), root = tabRoot(file);
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

	/** Files the workbench opens from the Explorer and the source-folder file index. */
	function isSource(path:String):Bool {
		if (languageServers != null && languageServers.client(path) != null) return true;
		if (path.endsWith(".hx") || path.endsWith(".rays") || isMarkdown(path) || ImagePreview.supports(path))
			return true;
		if (themeStudio != null)
			return path.endsWith(".css") || path.endsWith(".json") || path.endsWith(".md");
		return extension != null && (path.endsWith(".json") || path.endsWith(".svg") || path.endsWith(".css") || path.endsWith(".md"));
	}

	/** The file of the build's main class, when the build names one and a source folder has it; for an extension, its main script. */
	function mainFile():Null<String> {
		if (extension != null)
			return sys.FileSystem.exists(extension.mainPath()) ? extension.mainPath() : null;
		if (props.display.project != null && props.display.project.main != null && sys.FileSystem.exists(props.display.project.main)) return props.display.project.main;
		var args = props.display.args;
		for (i in 0...args.length - 1)
			if (args[i] == "--main" || args[i] == "-main" || args[i] == "-m")
				for (cp in classpaths()) {
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
		if (ImagePreview.isSvg(file)) imageTextMode(file).set(true);
		openFile(file);
		if (ImagePreview.isRaster(file)) return;
		var text = buffer(file).get(), offset = 0, at = 0;
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
		var ref = editorRefs.get(file);
		return ref == null ? null : ref.get();
	}

	function editorFind(replace = false):Void {
		var editor = editorOf(active.get());
		if (editor != null) editor.showFind(replace);
	}

	function editorFindNext(backward = false):Void {
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
		var editor = StringTools.endsWith(file, ".hx") || languageServers.client(file) != null ? editorOf(file) : null;
		if (editor != null)
			assist.typed(file, editor, buffer(file).get());
	}

	/** Keeps signature help showing while the text or the caret of a Haxe file moves inside a call. */
	function assistWatch(file:String, editor:Null<CodeEditor>):Void {
		if (editor == null || (!StringTools.endsWith(file, ".hx") && languageServers.client(file) == null))
			return;
		new ashui.reactive.Watch(() -> {
			editor.value.get();
			editor.editing.caret.get();
			0;
		}, _ -> assist.moved(file, editor), (_, _) -> false);
	}

	/** Opens the completion list at the caret of the Haxe file in front. */
	function triggerSuggest():Void {
		var file = active.get(), editor = file != "" && !isVirtual(file) && (StringTools.endsWith(file, ".hx") || languageServers.client(file) != null) ? editorOf(file) : null;
		if (editor != null)
			assist.complete(file, editor, buffer(file).get());
	}

	/** Shows the signatures of the call the caret of the Haxe file in front is in. */
	function triggerParameterHints():Void {
		var file = active.get(), editor = file != "" && !isVirtual(file) && (StringTools.endsWith(file, ".hx") || languageServers.client(file) != null) ? editorOf(file) : null;
		if (editor != null)
			assist.signature(file, editor, buffer(file).get());
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
		var line = 0, text = buffer(file).get();
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
		var client = languageServers.client(file), text = buffer(file).get(), originCaret = caret(file);
		if (client != null) {
			if (!client.supports("definitionProvider")) return;
			languageServers.sync(file, text);
			client.request("textDocument/definition", LspProtocol.at(file, text, offset), result -> {
				if (gone || active.get() != file || !buffers.exists(file) || buffer(file).get() != text || caret(file) != originCaret) return;
				var found = LspProtocol.locations(result);
				if (found.length == 0) say("No definition found");
				else goTo(found[0].file, found[0].range.start.line, found[0].range.start.character);
			}, file + "#definition");
			return;
		}
		var found = try props.display.definition(file, Display.byteOffset(buffer(file).get(), offset), buffer(file).get()) catch (_:Dynamic) [];
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

	/** Opens or closes the editor actions menu, as its button does. */
	public function showEditorMenu(on:Bool):Void
		if (menuRef.get() != null)
			menuRef.get().opened.set(on);

	/** The editor's actions, from the button at the end of the tab strip. */
	function editorMenu():Element {
		var noFile = Computed.make(() -> active.get() == ""), noSaved = Computed.make(() -> open.get().length == dirty.get().length);
		var mod = Sys.systemName() == "Mac" ? "⌘" : "Ctrl+";
		return <tooltip label="Editor actions" side="bottom">
			<dropdown-menu ref={menuRef} id="rayde-editor-menu">
				<dropdown-menu-trigger id="rayde-editor-menu-trigger" variant={Ghost} size={Icon} class="rayde-more"><icon document={Icons.MORE_FILL} class="size-4"/></dropdown-menu-trigger>
				<dropdown-menu-content>
					<dropdown-menu-item id="rayde-menu-save" shortcut={mod + "S"} onSelect={saveAll}>Save All</dropdown-menu-item>
					<dropdown-menu-separator/>
					<dropdown-menu-item id="rayde-menu-close" shortcut={mod + "W"} disabled={noFile} onSelect={() -> closeFile(active.get())}>Close Tab</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-close-others" disabled={noFile} onSelect={closeOthers}>Close Others</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-close-saved" disabled={noSaved} onSelect={closeSaved}>Close Saved</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-close-all" disabled={noFile} onSelect={closeAll}>Close All</dropdown-menu-item>
					<dropdown-menu-separator/>
					<dropdown-menu-item id="rayde-menu-copy-path" disabled={noFile} onSelect={() -> copyPath(false)}>Copy Path</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-copy-relative" disabled={noFile} onSelect={() -> copyPath(true)}>Copy Relative Path</dropdown-menu-item>
					<for {file in [active.get()]}>${titleItems(file)}</for>
				</dropdown-menu-content>
			</dropdown-menu>
		</tooltip>;
	}

	/** The items an extension adds to the editor's actions menu for the file in front, after a separator; none for a page that is not a file. */
	function titleItems(file:String):Element {
		var entries = isVirtual(file) || file == "" ? [] : contributedMenu("editor/title", file, "file");
		if (entries.length == 0)
			return <div/>;
		var items:Array<Element> = [<dropdown-menu-separator/>];
		for (entry in entries) {
			var e = entry.item, m = entry.extension;
			var icon = ViewIcons.named(m, e.icon), keys = bindings.label(extensionKey(m.id, e.command));
			var label = icon == null ? <text>${e.title}</text> : <div class="flex items-center justify-between gap-3 flex-1 min-w-0"><text>${e.title}</text><icon document={icon} class="size-4 shrink-0 text-text-secondary"/></div>;
			items.push(<dropdown-menu-item id={"rayde-menu-ext-" + (extension != null && m.id == extension.id ? "" : m.id + "-") + e.command} shortcut={keys} onSelect={() -> runExtensionCommand(m.id, e.command, file)}>${label}</dropdown-menu-item>);
		}
		return <div class="flex flex-col">{items}</div>;
	}

	/** Sets the bottom panel's height, as a drag of its handle would. */
	public function setPanelHeight(height:Float):Void
		problemsHeight.set(height);

	function current():Null<Session>
		return find(activeSession);

	function find(id:Int):Null<Session> {
		for (s in sessions)
			if (s.id == id)
				return s;
		return null;
	}

	/** The terminal in view, null when none runs. */
	public function terminal():Null<Terminal> {
		var s = current();
		return s == null ? null : s.terminal;
	}

	/** How many terminals are running. */
	public function terminalCount():Int
		return sessions.length;

	/** The ids of the terminals running, in the order they were started. */
	public function terminalIds():Array<Int>
		return [for (s in sessions) s.id];

	/** The terminals that share a screen with `id`, from left to right: the one itself when it is not split. */
	function groupOf(id:Int):Array<Session> {
		var s = find(id);
		return s == null ? [] : [for (o in sessions) if (o.group == s.group) o];
	}

	/** Ends every terminal. */
	public function closeTerminals():Void
		for (id in terminalIds())
			endSession(id);

	/** The profile a plain + starts: the one set as the default, else the first the machine offers, unless a test names a program. */
	function defaultProfile():Profile {
		if (terminalProgram != null)
			return {name: haxe.io.Path.withoutDirectory(terminalProgram), program: terminalProgram, args: terminalArgs};
		var all = Profiles.list();
		for (p in all)
			if (p.name == terminalSettings.defaultProfile)
				return p;
		return all.length > 0 ? all[0] : {name: "sh", program: "/bin/sh"};
	}

	/** Starts the first terminal if none runs. */
	function ensureTerminal():Void
		if (!starting && sessions.length == 0)
			startSession(defaultProfile());

	/** Runs `profile` in the project's folder, on the screen of `group` or a new one, and brings it to the front. */
	function startSession(profile:Profile, ?group:Int):Void {
		var t = Terminal.open(100, 12, props.display.cwd, profile.program, profile.args, true);
		if (t == null) {
			say("Could not start " + profile.name);
			return;
		}
		var session = {id: nextSession++, group: group == null ? nextGroup++ : group, terminal: t, profile: profile};
		sessions.push(session);
		activeSession = session.id;
		terminalActive.set(session.id);
		terminalGeneration.set(terminalGeneration.get() + 1);
	}

	/** Starts another terminal on a screen of its own, from `profile` or the default, beside the ones running, and gives it the keyboard. */
	public function newTerminal(?profile:Profile):Void {
		starting = true;
		showPanel("terminal");
		starting = false;
		startSession(profile == null ? defaultProfile() : profile);
		focusTerminal();
	}

	/** Splits the screen of the terminal in front, adding one beside it from `profile` or the same profile. */
	public function splitTerminal(?profile:Profile):Void {
		var s = current();
		if (s == null) {
			newTerminal(profile);
			return;
		}
		if (groupOf(s.id).length >= MAX_SPLITS) {
			say("A screen is split " + MAX_SPLITS + " ways at most");
			return;
		}
		startSession(profile == null ? s.profile : profile, s.group);
		focusTerminal();
	}

	/** Brings terminal `id` to the front, and its screen with it. */
	public function selectTerminal(id:Int):Void {
		var from = current(), to = find(id);
		if (to == null)
			return;
		activeSession = id;
		terminalActive.set(id);
		if (from == null || from.group != to.group)
			terminalGeneration.set(terminalGeneration.get() + 1);
		focusTerminal();
	}

	/** Notes that the view of terminal `id` has the keyboard, which makes it the one in front. */
	function noteFocus(id:Int):Void
		if (activeSession != id && find(id) != null) {
			activeSession = id;
			terminalActive.set(id);
		}

	/** Ends the terminal in front; one beside it, or the neighbouring screen, comes forward, and with none left the pane offers a new one. */
	public function killTerminal():Void
		endSession(activeSession);

	function endSession(id:Int):Void {
		var at = -1;
		for (i => s in sessions)
			if (s.id == id)
				at = i;
		if (at < 0)
			return;
		var group = sessions[at].group;
		sessions[at].terminal.close();
		sessions.splice(at, 1);
		views.remove(id);
		if (activeSession == id) {
			var peers = [for (s in sessions) if (s.group == group) s];
			activeSession = peers.length > 0 ? peers[peers.length - 1].id : sessions.length == 0 ? -1 : sessions[Std.int(Math.min(at, sessions.length - 1))].id;
			terminalActive.set(activeSession);
		}
		terminalGeneration.set(terminalGeneration.get() + 1);
	}

	/** Makes `name` the profile + starts, and keeps it. */
	public function setDefaultProfile(name:String):Void {
		terminalSettings.defaultProfile = name;
		terminalSettings.save(props.display.cwd);
		settingsRevision.set(settingsRevision.get() + 1);
	}

	/** Opens or closes the menu of terminal profiles, as its button does. */
	public function showTerminalMenu(on:Bool):Void
		if (profilesMenu.get() != null)
			profilesMenu.get().opened.set(on);

	/** Opens the Settings page on the terminal's section. */
	public function openTerminalSettings():Void
		openSettings("terminal");

	/** The profiles of the machine as choices, each doing `then` with its profile when chosen. */
	function profileChoices(then:Profile->Void):Array<CenterAction> {
		var out:Array<CenterAction> = [];
		for (p in Profiles.list())
			out.push({
				id: "profile-" + p.name,
				label: p.name + (p.name == defaultProfile().name ? " (default)" : ""),
				icon: p.name == defaultProfile().name ? Icons.CHECK_LINE : Icons.TERMINAL_BOX_LINE,
				shortcut: p.program,
				run: () -> then(p)
			});
		return out;
	}

	public function splitWithProfile():Void
		openPicker("Split the terminal with a profile", profileChoices(p -> splitTerminal(p)));

	public function selectDefaultProfile():Void
		openPicker("Select the default profile", profileChoices(p -> setDefaultProfile(p.name)));

	/** Opens the center to choose among `items`, in place of its files and commands. */
	function openPicker(placeholder:String, items:Array<CenterAction>):Void {
		centerRequest.set({text: "", serial: centerRequest.get().serial + 1, picker: {placeholder: placeholder, items: items}});
		quickOpen.set(true);
	}

	// Tasks

	/** The project's tasks as choices for the center, each run in a terminal of its own. */
	function taskChoices():Array<CenterAction> {
		var out:Array<CenterAction> = [];
		for (i => t in Tasks.list(props.display))
			out.push({id: "task-" + i, label: t.label, icon: Icons.PLAY_FILL, shortcut: t.detail, run: () -> runTask(t)});
		return out;
	}

	/** Runs `task` in a new terminal, which stays after the command ends so its output can be read. */
	public function runTask(task:Task):Void {
		var windows = Sys.systemName() == "Windows";
		starting = true;
		showPanel("terminal");
		starting = false;
		startSession({name: task.label, program: windows ? "cmd.exe" : "/bin/sh", args: [windows ? "/c" : "-c", task.command]});
		focusTerminal();
	}

	public function runTaskPicker():Void {
		var tasks = taskChoices();
		if (tasks.length == 0)
			say("No tasks. Configure Tasks adds some");
		else
			openPicker("Run a task", tasks);
	}

	/** Opens the project's tasks file, made with an example when there is none. */
	public function configureTasks():Void
		openFile(Tasks.ensure(props.display.cwd));

	/** Opens the panel on the terminal and gives it the keyboard, or closes the panel when the terminal is what it shows. */
	public function toggleTerminal():Void {
		if (panelShown.get() && bottom.get() == "terminal") {
			closePanel();
			return;
		}
		showPanel("terminal");
		focusTerminal();
	}

	/** Once the view of the terminal in front is made, gives it the keyboard. */
	public function focusTerminal():Void {
		var tries = 0, hook:ashui.layout.LayoutTree->Void = null;
		hook = _ -> {
			var ref = views.get(activeSession), view = ref == null ? null : ref.get();
			if (view != null && panelShown.get()) {
				ashui.layout.LayoutTree.flushHooks.remove(hook);
				view.focus();
			} else if (++tries > 30)
				ashui.layout.LayoutTree.flushHooks.remove(hook);
		};
		ashui.layout.LayoutTree.flushHooks.push(hook);
	}

	/** Whether the bottom panel, Problems and Output, is open. */
	public function panelOpen():Bool
		return panelShown.get();

	/** Opens the bottom panel on `tab`: problems or console, which it calls Output. */
	public function showPanel(tab:String):Void {
		bottom.set(tab);
		if (!panelShown.get())
			problemsHeight.set(panelHeight);
	}

	public function closePanel():Void
		problemsHeight.set(0);

	public function togglePanel():Void
		if (panelShown.get())
			closePanel();
		else
			problemsHeight.set(panelHeight);

	/** Tells the stylesheet whether the panel is closed, so the handle above it goes with it. */
	function markPanel(shown:Bool):Void {
		var hook:ashui.layout.LayoutTree->Void = null;
		hook = _ -> {
			ashui.layout.LayoutTree.flushHooks.remove(hook);
			var rows = rowsRef.get();
			if (rows != null)
				for (id in ashui.css.Css.query(rows.tree, rows.node.id, "#rayde-rows > .ui-resizable-handle"))
					ashui.css.Identity.of(rows.tree, id).setAttribute("data-closed", shown ? null : "");
		};
		ashui.layout.LayoutTree.flushHooks.push(hook);
	}

	/** Folds the Explorer away, leaving the activity bar, or brings it back. */
	function toggleExplorer():Void
		treeWidth.set(explorerShown.get() ? ACTIVITY : ACTIVITY + EXPLORER_WIDTH);

	/** Moves the cursor of the file in front to `line` (from 1). */
	function goToLine(line:Int):Void {
		var file = active.get();
		if (file != "")
			goTo(file, line - 1, 0);
	}

	/** The commands: what the center lists after `>`, what the Settings page lets a key be chosen for, and what a key runs. */
	function commands():Array<CenterAction>
		return [
			{id: "quickopen", label: "Go to File...", icon: Icons.SEARCH_LINE, run: () -> openCenter()},
			{id: "commands", label: "Show All Commands", icon: Icons.CODE_BOX_LINE, run: () -> openCenter(">")},
			{id: "gotoline", label: "Go to Line...", icon: Icons.ARROW_RIGHT_LINE, run: () -> openCenter(":")},
			{id: "find", label: "Find", icon: Icons.SEARCH_LINE, run: () -> editorFind()},
			{id: "replace", label: "Replace", icon: Icons.FIND_REPLACE_LINE, run: () -> editorFind(true)},
			{id: "findnext", label: "Find Next", icon: Icons.ARROW_DOWN_LINE, run: () -> editorFindNext()},
			{id: "findprevious", label: "Find Previous", icon: Icons.ARROW_UP_LINE, run: () -> editorFindNext(true)},
			{id: "run", label: "Run", icon: Icons.PLAY_FILL, run: run},
			{id: "stop", label: "Stop", icon: Icons.STOP_FILL, run: stopRun},
			{id: "save", label: "Save All", icon: Icons.SAVE_3_LINE, run: saveAll},
			{id: "close", label: "Close Tab", icon: Icons.CLOSE_LINE, run: () -> if (active.get() != "") closeFile(active.get())},
			{id: "definition", label: "Go to Definition", icon: Icons.CORNER_DOWN_RIGHT_LINE, run: goToDefinition},
			{id: "suggest", label: "Trigger Suggest", icon: Icons.LIGHTBULB_LINE, run: triggerSuggest},
			{id: "parameterhints", label: "Trigger Parameter Hints", icon: Icons.BRACES_LINE, run: triggerParameterHints},
			{id: "settings", label: "Open Settings", icon: Icons.SETTINGS_3_LINE, run: () -> openSettings()},
			{id: "build", label: "Open Build Settings", icon: Icons.HAMMER_LINE, run: openBuild},
			{id: "libraries", label: "Manage Libraries", icon: Icons.BOOK_2_LINE, run: () -> openSettings("libraries")},
			{id: "colorscheme", label: "Color Scheme", icon: Icons.PALETTE_LINE, run: () -> openSettings("appearance")},
			{id: "keybindings", label: "Open Keyboard Shortcuts", icon: Icons.KEYBOARD_LINE, run: () -> openSettings("keys")},
			{id: "keymap", label: "Select Keymap...", icon: Icons.KEYBOARD_LINE, run: selectKeymap},
			{id: "extensions", label: "Show Extensions", icon: Icons.PUZZLE_LINE, run: () -> openSettings("extensions")},
			{id: "problems", label: "Show Problems", icon: Icons.CLOSE_CIRCLE_LINE, run: () -> showPanel("problems")},
			{id: "output", label: "Show Output", icon: Icons.TERMINAL_BOX_LINE, run: () -> showPanel("console")},
			{id: "extension", label: "Show Extension Console", icon: Icons.PUZZLE_LINE, run: () -> showPanel("extension")},
			{id: "newfile", label: "New File…", icon: Icons.FILE_ADD_LINE, run: () -> askCreate(selectedFolder(), false)},
			{id: "newfolder", label: "New Folder…", icon: Icons.FOLDER_ADD_LINE, run: () -> askCreate(selectedFolder(), true)},
			{id: "filerename", label: "Rename File…", icon: Icons.EDIT_LINE, run: () -> withSelected(askRename)},
			{id: "filedelete", label: "Delete File…", icon: Icons.DELETE_BIN_LINE, run: () -> withSelected(askDelete)},
			{id: "filecopy", label: "Copy File", icon: Icons.FILE_COPY_LINE, run: () -> withSelected(p -> copyFile(p, false))},
			{id: "filecut", label: "Cut File", icon: Icons.SCISSORS_LINE, run: () -> withSelected(p -> copyFile(p, true))},
			{id: "filepaste", label: "Paste File", icon: Icons.CLIPBOARD_LINE, run: () -> pasteFiles(selectedFolder())},
			{id: "fileduplicate", label: "Duplicate File", icon: Icons.FILE_COPY_2_LINE, run: () -> withSelected(duplicateFile)},
			{id: "filecopypath", label: "Copy File Path", icon: Icons.LINK_M, run: () -> withSelected(p -> ashui.input.Clipboard.setText(p))},
			{id: "filecopyrelative", label: "Copy Relative File Path", icon: Icons.LINK_M, run: () -> withSelected(p -> ashui.input.Clipboard.setText(FileOps.relative(props.display.cwd, p)))},
			{id: "filereveal", label: Sys.systemName() == "Mac" ? "Reveal File in Finder" : "Reveal File in File Manager", icon: Icons.FOLDER_OPEN_LINE, run: () -> withSelected(FileOps.reveal)},
			{id: "minimize", label: "Minimize Window", icon: Icons.SUBTRACT_LINE, run: () -> chrome.minimize()},
			{id: "fullscreen", label: "Toggle Full Screen", icon: Icons.FULLSCREEN_LINE, run: () -> chrome.toggleFullscreen()},
			{id: "maximize", label: "Toggle Maximize Window", icon: Icons.CHECKBOX_BLANK_LINE, run: () -> chrome.toggleMaximize()},
			{id: "togglebreakpoint", label: "Toggle Breakpoint", icon: Icons.CIRCLE_FILL, run: toggleBreakpoint},
			{id: "continue", label: "Continue", icon: Icons.PLAY_FILL, run: () -> debugResume("continue")},
			{id: "pause", label: "Pause Extension", icon: Icons.PAUSE_FILL, run: () -> {
				var d = debugger();
				if (d != null)
					d.pause();
			}},
			{id: "stepover", label: "Step Over", icon: Icons.ARROW_GO_FORWARD_LINE, run: () -> debugResume("stepOver")},
			{id: "stepinto", label: "Step Into", icon: Icons.CORNER_RIGHT_DOWN_LINE, run: () -> debugResume("stepIn")},
			{id: "stepout", label: "Step Out", icon: Icons.CORNER_UP_RIGHT_LINE, run: () -> debugResume("stepOut")},
			{id: "clearbreakpoints", label: "Remove All Breakpoints", icon: Icons.DELETE_BIN_LINE, run: () -> {
				var d = debugger();
				if (d != null)
					d.clear();
			}},
			{id: "extensionreload", label: "Reload Extension", icon: Icons.REFRESH_LINE, run: () -> if (extension != null) extensionStudio().reload() else if (isExtension(active.get())) studioOf(active.get()).reload()},
			{id: "terminal", label: "Open Terminal", icon: Icons.TERMINAL_BOX_LINE, run: toggleTerminal},
			{id: "newterminal", label: "New Terminal", icon: Icons.ADD_LINE, run: () -> newTerminal()},
			{id: "splitterminal", label: "Split Terminal", icon: Icons.LAYOUT_COLUMN_LINE, run: () -> splitTerminal()},
			{id: "terminalprofile", label: "Select Default Terminal Profile", icon: Icons.TERMINAL_BOX_LINE, run: selectDefaultProfile},
			{id: "terminalsettings", label: "Configure Terminal Settings", icon: Icons.SETTINGS_3_LINE, run: openTerminalSettings},
			{id: "runtask", label: "Run Task", icon: Icons.PLAY_FILL, run: runTaskPicker},
			{id: "configuretasks", label: "Configure Tasks", icon: Icons.CODE_BOX_LINE, run: configureTasks},
			{id: "panel", label: "Toggle Panel", icon: Icons.LAYOUT_BOTTOM_LINE, run: togglePanel},
			{id: "explorer", label: "Toggle Explorer", icon: Icons.FOLDERS_LINE, run: toggleExplorer}
		].concat(contributedCommands());

	/** Namespaced bindings let extensions declare the same local command id. */
	static function extensionKey(id:String, command:String):String return Manager.commandKey(id, command);

	function contributedCommands():Array<CenterAction> {
		if (extensionManager == null) return [];
		var out:Array<CenterAction> = [];
		for (e in extensionManager.enabled()) {
			var m = e.connection.manifest;
			for (c in m.commands) out.push({id: extensionKey(m.id, c.id), label: c.title, icon: ViewIcons.named(m, c.icon) ?? Icons.PUZZLE_LINE,
				run: () -> runExtensionCommand(m.id, c.id, (explorerFocused() ? selectedPath() : null) ?? realFile(active.get()))});
		}
		return out;
	}

	function runExtensionCommand(id:String, command:String, path:Null<String>):Void {
		var kind:Null<String> = path == null ? null : sys.FileSystem.exists(path) && sys.FileSystem.isDirectory(path) ? "folder" : "file";
		if (!extensionManager.command(id, command, {path: path, kind: kind})) say('Extension $id is not running.');
	}

	function contributedMenu(location:String, path:String, kind:String):Array<{extension:Manifest, item:rayde.ext.Manifest.MenuEntry}> {
		var out = [];
		for (e in extensionManager.enabled()) {
			var m = e.connection.manifest;
			for (item in m.menuFor(location, path, kind)) out.push({extension: m, item: item});
		}
		return out;
	}

	/** Writes each command's key beside it, as the center shows them; asked again when a binding changes. */
	function refreshShortcuts():Void
		for (a in commandList)
			a.shortcut = bindings.label(a.id);

	/** What follows a change to a key: the center's labels, and the Settings page. */
	function bindingsChanged():Void {
		refreshShortcuts();
		bindingsRevision.set(bindingsRevision.get() + 1);
	}

	/** Whether the key pressed does a command the terminal gives up its keyboard for. */
	function reservedKey(e:KeyEvent):Bool {
		var chord = Chord.ofEvent(e.key, e.shift, e.control, e.alt, e.superKey), id = chord == null ? null : bindings.commandFor(chord);
		return id != null && terminalKeepsOut.indexOf(id) >= 0;
	}

	/** Takes the keys of the keymap `id`, keeps the choice, and shows it everywhere keys are shown. */
	public function useKeymap(id:String):Void {
		bindings.setPreset(id);
		bindings.save(props.display.cwd);
		bindingsChanged();
		say("Keymap: " + Keymaps.find(id).label);
	}

	/** Opens the center to choose a keymap, those of the editors people know. */
	public function selectKeymap():Void
		openPicker("Select a keymap", [
			for (m in Keymaps.available(bindings.mac))
				{id: m.id, label: m.label + (m.id == bindings.preset ? "  (current)" : ""), icon: Icons.KEYBOARD_LINE, run: () -> useKeymap(m.id)}
		]);

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

	/** The editor's text for `file`, read from disk when first opened. */
	public function buffer(file:String):Signal<String> {
		if (ImagePreview.isRaster(file)) throw "Image files are not text documents";
		var b = buffers.get(file);
		if (b == null) {
			var disk = sys.io.File.getContent(file), recovered = localHistory.recover(file, disk);
			b = Signal.make(recovered);
			buffers.set(file, b);
			if (recovered != disk && dirty.get().indexOf(file) < 0) {
				ashui.animation.AnimationScheduler.main.after(.01, () -> {
					if (gone || !buffers.exists(file)) return;
					if (dirty.get().indexOf(file) < 0) dirty.set(dirty.get().concat([file]));
					say("Recovered unsaved changes in " + haxe.io.Path.withoutDirectory(file));
				});
			}
		}
		return b;
	}

	function documentState(file:String):CodeEditorState {
		var state = documents.get(file);
		if (state == null) {
			state = new CodeEditorState(buffer(file));
			DocumentHistory.restore(state, localHistory.undo(file, state.value.get()));
			documents.set(file, state);
		}
		return state;
	}

	/** Closed saved files need no cache. Unsaved text and live development previews still do. */
	function releaseClosedDocuments():Void {
		var opened = open.get(), changed = dirty.get();
		if (languageServers != null) languageServers.retain(opened);
		for (file in imageViews.keys()) if (opened.indexOf(file) < 0 && changed.indexOf(file) < 0) imageViews.remove(file);
		for (file in imageTextModes.keys()) if (opened.indexOf(file) < 0 && changed.indexOf(file) < 0) imageTextModes.remove(file);
		for (file in localHistory.files()) if (opened.indexOf(file) < 0 && changed.indexOf(file) < 0) localHistory.forget(file);
		for (file in nativeSyntax.keys())
			if (opened.indexOf(file) < 0 && changed.indexOf(file) < 0) {
				var syntax = nativeSyntax.get(file);
				if (syntax != null) syntax.dispose();
				nativeSyntax.remove(file);
			}
		for (file in documents.keys())
			if (opened.indexOf(file) < 0 && changed.indexOf(file) < 0)
				documents.remove(file);
		for (file in editorRefs.keys())
			if (opened.indexOf(file) < 0)
				editorRefs.remove(file);
		for (file in buffers.keys())
			if (opened.indexOf(file) < 0 && changed.indexOf(file) < 0 && !studios.exists(file)
				&& (themeStudio == null || themeStudio.file != file))
				buffers.remove(file);
	}

	/** Records that `file`'s buffer has changed since it was last written, and checks it as it now is. */
	public function edited(file:String):Void {
		checkpointHistory(file);
		if (dirty.get().indexOf(file) < 0)
			dirty.set(dirty.get().concat([file]));
		check(file);
		var studio = studios.get(file);
		if (themeStudio != null && file == themeStudio.file)
			themeStudio.edited();
		if (studio != null)
			studio.edited();
		else if (extension != null && isExtension(file))
			extensionStudio().edited();
		emit("file.changed", {path: file}, .3);
		followBreakpoints(file);
	}

	function checkpointHistory(file:String):Void {
		var state = documents.get(file), text = buffer(file).get();
		var before = localHistory.current(file, text);
		localHistory.record(file, before, text, state == null ? null : DocumentHistory.snapshot(state));
		if (historyPending.exists(file)) return;
		historyPending.set(file, true);
		ashui.animation.AnimationScheduler.main.after(.35, () -> { historyPending.remove(file); if (!gone) localHistory.flush(file); });
	}

	function previewHistory(file:String, revision:Int):Void {
		var id = HISTORY_TAB + file + "#" + revision;
		historyTabs.set(id, {file:file, revision:revision, text:localHistory.revision(file, buffer(file).get(), revision)}); openFile(id);
	}

	function restoreHistory(file:String, text:String):Void {
		openFile(file);
		var attempts = 0;
		function apply():Void {
			var editor = editorOf(file);
			if (editor != null && active.get() == file) editor.applyEdits([{from:0, to:buffer(file).get().length, text:text}]);
			else if (!gone && ++attempts < 80) ashui.animation.AnimationScheduler.main.after(.02, apply);
		}
		ashui.animation.AnimationScheduler.main.after(.02, apply);
	}

	function historyPage(id:String):Element {
		var entry = historyTabs.get(id);
		if (entry == null) return <div/>;
		var text = entry.text;
		return <div class="flex flex-col flex-1 min-h-0">
			<div class="flex items-center gap-2 px-3 py-2 shrink-0 border-b">
				<text class="text-xs text-text-secondary flex-1">Local revision ${Std.string(entry.revision)} · ${haxe.io.Path.withoutDirectory(entry.file)}</text>
				<tooltip label="Restore this revision to the unsaved buffer; the change can be undone" side="bottom"><button id="rayde-history-restore" variant={Ghost} size={Icon} onClick={_ -> restoreHistory(entry.file, text)}><icon document={Icons.HISTORY_LINE} class="size-4"/></button></tooltip>
			</div>
			<code-view id="rayde-history-preview" value={text} language={languageOf(entry.file)} lineNumbers={true} minimap={false} class="flex-1 min-h-0"/>
		</div>;
	}

	/** Files whose breakpoints are about to be read back from the editor. */
	final following = new Map<String, Bool>();

	/** Whether the workbench has been taken down, so a timer that was waiting changes nothing. */
	var gone = false;

	/** Breakpoints move with the text; once the editor has moved them, the debugger learns where they are now. */
	function followBreakpoints(file:String):Void {
		if (following.exists(file) || debuggerOf(file) == null)
			return;
		following.set(file, true);
		ashui.animation.AnimationScheduler.main.after(.03, () -> {
			following.remove(file);
			if (gone)
				return;
			var state = documents.get(file), d = debuggerOf(file);
			if (state != null && state.annotations != null && d != null)
				d.setLines(file, [for (l in state.annotations.markerLinesOf("breakpoints")) l + 1]);
		});
	}

	/** The Studio running the extension whose main file is `file`, if it is open. */
	public function studioFor(file:String):Null<Studio>
		return studios.get(file);

	static function isExtension(file:String):Bool
		return StringTools.endsWith(file, ".rays");

	/** The breakpoints kept for this project, by file. */
	function readBreakpoints():Array<rayde.ext.Debugger.Breakpoint> {
		var saved = Store.section(props.display.cwd, "breakpoints"), out = [];
		for (rel in Reflect.fields(saved)) {
			var lines:Dynamic = Reflect.field(saved, rel);
			if (Std.isOfType(lines, Array))
				for (l in (lines : Array<Dynamic>))
					out.push({file: haxe.io.Path.join([props.display.cwd, rel]), line: Std.int(l)});
		}
		return out;
	}

	function saveBreakpoints(d:Debugger):Void {
		var saved:Dynamic = {};
		for (b in d.breakpoints.get()) {
			var rel = relative(b.file);
			var lines:Array<Int> = Reflect.hasField(saved, rel) ? Reflect.field(saved, rel) : [];
			lines.push(b.line);
			Reflect.setField(saved, rel, lines);
		}
		Store.save(props.display.cwd, "breakpoints", saved);
	}

	/** The extension stopped: its place is shown in the editor and its stack and variables in the panel. */
	function showStop(studio:Studio, stop:rayde.ext.Debugger.Stop):Void {
		var top = stop.frames[0];
		if (top != null && sys.FileSystem.exists(top.file))
			goTo(top.file, top.line - 1, Std.int(Math.max(0, top.col - 1)));
		studio.panel.set("debug");
		showPanel("extension");
	}

	/** The debugger of the extension in front, if there is one. */
	function debugger():Null<Debugger> {
		var studio = extension != null ? extensionStudio() : studios.get(active.get());
		return studio == null ? null : studio.debug;
	}

	/** Puts a breakpoint on the line the cursor is on in the file in front, or takes the one there away. */
	function toggleBreakpoint():Void {
		var file = realFile(active.get());
		var d = debugger();
		if (file == null || !isExtension(file) || d == null) {
			say("Breakpoints go on a line of a RayScript file");
			return;
		}
		var line = caretLine(file);
		if (line < 0)
			return;
		say(d.toggle(file, line + 1) ? "Breakpoint on " + haxe.io.Path.withoutDirectory(file) + ":" + (line + 1) : "Breakpoint removed");
	}

	/** Lets the stopped extension go on as `how` says; said so when none is stopped. */
	function debugResume(how:String):Void {
		var d = debugger();
		if (d == null || d.stopped.get() == null)
			say("The extension is not stopped");
		else
			d.resume(how);
	}

	/** The Theme Studio of the theme file `file`: it reads the editor's text, and what it writes goes to the editor and the file. */
	function makeThemeStudio(file:String):ThemeStudio {
		var studio = new ThemeStudio(file, () -> buffer(file).get(), text -> {
			localHistory.record(file, buffer(file).get(), text, null, "Theme edit");
			buffer(file).set(text);
			sys.io.File.saveContent(file, text);
			localHistory.saved(file, text, null);
			dirty.set([for (d in dirty.get()) if (d != file) d]);
		}, () -> appearance);
		// What is wrong with the theme is a problem of its file: underlined in the editor and listed with the others.
		new ashui.reactive.Watch(() -> studio.problems.get(), list -> {
			var text = buffer(file).get();
			problems.set([for (p in problems.get()) if (p.file != file) p].concat([for (p in list) themeProblem(file, text, p)]));
		});
		return studio;
	}

	/** A problem of a theme file as a diagnostic: on the entry it names, or, for text that is not JSON, where the parser stopped. */
	static function themeProblem(file:String, text:String, p:rayde.theme.ThemeFile.Problem):Diagnostic {
		var span = p.at == null ? null : JsonLocator.find(text, p.at);
		var start = span != null ? span.keyStart : 0, end = span != null ? span.keyEnd : 0;
		if (span == null) {
			var stopped = ~/at position (\d+)/;
			if (stopped.match(p.message)) {
				start = Std.parseInt(stopped.matched(1));
				end = start + 1;
			}
		}
		var from = JsonLocator.position(text, start), to = JsonLocator.position(text, end);
		return {file: file, range: {start: {line: from.line, character: from.character}, end: {line: to.line, character: to.character}}, severity: StringTools.startsWith(p.message, "Invalid JSON") ? 1 : 2, message: p.message};
	}

	/** The theme being written, when this project is one. */
	public function themeModel():Null<ThemeStudio>
		return themeStudio;

	/** Brings the Theme Studio page forward. */
	public function openThemeStudio():Void
		if (themeStudio != null)
			openFile(THEME_TAB);

	/** Opens the theme file as text, with the cursor on the entry at `at` (`dark.colors.primary`) when the text has it. */
	function openThemeText(at:Null<String>):Void {
		if (themeStudio == null)
			return;
		var file = themeStudio.file, span = at == null ? null : JsonLocator.find(buffer(file).get(), at);
		if (span == null)
			openFile(file);
		else {
			var where = JsonLocator.position(buffer(file).get(), span.keyStart);
			goTo(file, where.line, where.character);
		}
	}

	/** Switches the window to the light or dark scheme and keeps the choice. */
	function pickScheme(scheme:String):Void {
		if (appearance.scheme == scheme)
			return;
		appearance.scheme = scheme;
		appearance.save(props.display.cwd);
		Theming.apply(appearance);
		settingsRevision.set(settingsRevision.get() + 1);
	}

	/** The Studio for an extension's main file, started the first time it is asked for. */
	function studioOf(file:String):Studio {
		var studio = studios.get(file);
		if (studio != null)
			return studio;
		var own = extension != null && extension.mainPath() == file ? extension : null;
		studio = new Studio(file, () -> buffer(file).get(), tree, own);
		studios.set(file, studio);
		studio.services = services();
		studio.debug.load(readBreakpoints());
		studio.debug.onChange = () -> saveBreakpoints(studio.debug);
		studio.debug.onStop = stop -> showStop(studio, stop);
		studio.onTabs = list -> syncTabs(studio, list);
		studio.onProblems = list -> problems.set([for (p in problems.get()) if (p.file != file) p].concat(list));
		studio.onError = kind -> {
			if (panelShown.get())
				return;
			showPanel(kind == "syntax" || kind == "compile" ? "problems" : "extension");
		};
		studio.reload();
		return studio;
	}

	function startExtensions():Void {
		extensionManager = new Manager(props.display.cwd, {builtins: Extensions.builtins(), user: haxe.io.Path.join([Extensions.home(), ".rayde", "extensions"]),
			defaultEvents: ["onStartup"], restartLimit: 3, restartWindow: 60});
		extensionManager.onDiscover = entry -> {
			var m = entry.connection.manifest, dev = entry.installed.scope == "Development";
			if (dev) { entry.connection.source = () -> buffer(entry.connection.file).get(); entry.connection.useMocks = true; }
			var studio = new Studio(m.mainPath(), () -> entry.connection.source(), tree, m, entry.connection);
			studio.managed = true;
			studio.development = dev;
			studio.live.set(dev);
			studios.set(m.mainPath(), studio);
			studio.onTabs = list -> syncTabs(studio, list);
			studio.onProblems = list -> problems.set([for (p in problems.get()) if (p.file != studio.file) p].concat(list));
			entry.onDisabled = disabled -> {
				if (disabled) { studio.clearView(); syncTabs(studio, []); }
			};
			if (dev) {
				studio.debug.load(readBreakpoints());
				studio.debug.onChange = () -> saveBreakpoints(studio.debug);
				studio.debug.onStop = stop -> showStop(studio, stop);
			}
		};
		extensionManager.discover(services(), Extensions.disabled(props.display.cwd), extension);
		extensionManager.onChanged = () -> {
			extensionRevision.set(extensionRevision.get() + 1);
			if (!supervisionScheduled && Lambda.exists(extensionManager.extensions, e -> !e.disabled && !e.restartBlocked && e.activation != null && e.connection.state == "exited")) {
				supervisionScheduled = true;
				ashui.animation.AnimationScheduler.main.after(.016, superviseExtensions);
			}
		};
		extensionManager.onOutput = entry -> {
			if (outputChannel.get() == "ext:" + entry.installed.id) {
				extensionOutputDirty = true;
				if (panelShown.get() && bottom.get() == "console") refreshExtensionOutput();
			}
		};
		refreshExtensionBindings();
		ashui.animation.AnimationScheduler.main.after(.016, () -> { if (!gone) extensionManager.start(); });
	}

	function superviseExtensions():Void {
		supervisionScheduled = false;
		if (gone) return;
		extensionManager.tick(null, false);
	}

	function wakeLanguages(urgent = true):Void {
		if (gone || !languageServers.busy()) {
			if (languagePollTimer != null) languagePollTimer.cancel();
			languagePollTimer = null;
			languagesScheduled = false;
			return;
		}
		if (languagesScheduled && !urgent) return;
		if (languagePollTimer != null) languagePollTimer.cancel();
		languagesScheduled = true;
		languagePollTimer = ashui.animation.AnimationScheduler.main.after(urgent ? .016 : languageServers.pollDelay(), pollLanguages);
	}

	function pollLanguages():Void {
		languagePollTimer = null;
		languagesScheduled = false;
		if (gone || !languageServers.busy()) return;
		languageServers.tick();
		wakeLanguages(false);
	}

	function refreshExtensionBindings():Void {
		var keys = [], owners = new Map<String, Array<String>>();
		for (e in extensionManager.extensions) {
			var m = e.connection.manifest;
			for (command in m.commands) {
				var old = "ext." + command.id, targets = owners.get(old);
				if (targets == null) { targets = []; owners.set(old, targets); }
				targets.push(extensionKey(m.id, command.id));
			}
			if (!e.disabled) for (key in m.keybindings) keys.push({command: extensionKey(m.id, key.command), key: key.key});
		}
		bindings.setContributions(keys);
		bindings.migrateExtensions(props.display.cwd, owners);
	}

	function toggleExtension(id:String, disabled:Bool):Void {
		Extensions.setDisabled(props.display.cwd, id, disabled);
		extensionManager.setDisabled(id, disabled);
		containers = makeContainers();
		if (!Lambda.exists(containers, c -> c.id == sideView.get())) sideView.set("explorer");
		open.set([for (f in open.get()) if (!isViewTab(f) || containerOfTab(f) != null) f]);
		if (open.get().indexOf(active.get()) < 0) active.set(open.get().length == 0 ? "" : open.get()[0]);
		commandList.splice(0, commandList.length);
		for (a in commands()) commandList.push(a);
		refreshExtensionBindings();
		bindingsChanged();
		layoutRevision.set(layoutRevision.get() + 1);
	}

	function refreshExtensionOutput():Void {
		var channel = outputChannel.get();
		if (channel == "build") return;
		var kinds = outputKinds.exists(channel) ? outputKinds.get(channel) : [];
		if (extensionOutputKinds.get() != kinds) extensionOutputKinds.set(kinds);
		var entry = extensionManager.find(channel.substr(4));
		outputJobs.request(channel, entry == null ? [] : entry.output, entry == null ? [] : entry.outputKinds);
		extensionOutputDirty = false;
		if (!outputScheduled) {
			outputScheduled = true;
			ashui.animation.AnimationScheduler.main.after(.016, pollOutput);
		}
	}

	function pollOutput():Void {
		if (gone) return;
		for (result in outputJobs.poll()) if (result.value != null) {
			var next = result.value, channel = result.key;
			if (channel != "build" && channel != outputChannel.get()) continue;
			var previous = outputSpans.get(channel), changedStyle = !AnsiOutput.sameSpans(previous, next.spans);
			if (changedStyle) { outputSpans.set(channel, next.spans); outputStyleRevision.set(outputStyleRevision.get() + 1); }
			outputState(channel).value.set(next.text);
			if (channel != "build") {
				var kinds = extensionOutputKinds.get(), changed = kinds.length != next.kinds.length;
				if (!changed) for (i in 0...kinds.length) if (kinds[i] != next.kinds[i]) { changed = true; break; }
				if (changed) extensionOutputKinds.set(next.kinds);
				outputKinds.set(channel, extensionOutputKinds.get());
			}
		}
		outputScheduled = outputJobs.busy();
		if (outputScheduled) ashui.animation.AnimationScheduler.main.after(.016, pollOutput);
		else if (outputRevealChannel != null) {
			var reveal = outputRevealChannel == outputChannel.get();
			outputRevealChannel = null;
			if (reveal) ashui.animation.AnimationScheduler.main.after(.016, () -> revealExtensionOutput());
		}
	}

	function outputState(channel:String):CodeEditorState {
		var state = outputStates.get(channel);
		if (state == null) {
			state = new CodeEditorState(channel == "build" ? consoleText : Signal.make(""));
			outputStates.set(channel, state);
		}
		return state;
	}

	function revealExtensionOutput(tries = 0):Void {
		if (gone || !panelShown.get() || bottom.get() != "console" || outputChannel.get() == "build") return;
		if (outputScheduled) { outputRevealChannel = outputChannel.get(); return; }
		var view = extensionOutputView.get();
		var bounds = view == null ? null : view.tree.getBounds(view.node);
		if (view == null || view.scroll == null || bounds == null || bounds.height <= 0) {
			if (tries < 20) ashui.animation.AnimationScheduler.main.after(.01, () -> revealExtensionOutput(tries + 1));
			return;
		}
		var end = view.value.get().length;
		view.select(end, end);
		view.scroll.scrollTo(0, 1e12);
	}

	/** Resolves a path an extension gave against the project, refusing one outside it. */
	function projectPath(path:String):String {
		var full = haxe.io.Path.normalize(haxe.io.Path.isAbsolute(path) ? path : haxe.io.Path.join([props.display.cwd, path]));
		if (!FileOps.inside(props.display.cwd, full))
			throw "That is outside the project.";
		return full;
	}

	/** Reads a project image within the preview's file-size budget. */
	function imageBytes(path:String):Null<haxe.io.Bytes> {
		var full = projectPath(path);
		if (!sys.FileSystem.exists(full) || sys.FileSystem.isDirectory(full)) return null;
		if (sys.FileSystem.stat(full).size > 8 * 1024 * 1024) throw "Preview images are limited to 8 MiB";
		return sys.io.File.getBytes(full);
	}

	/** What an extension may ask of the workbench through `rayde.workspace`. */
	function services():Services
		return {
			registerLanguage:(owner, definition, log) -> languageServers.register(owner, definition, log),
			unregisterLanguage:(owner, id) -> languageServers.unregister(owner, id),
			languageServers:owner -> languageServers.servers(owner),
			releaseLanguages:owner -> languageServers.release(owner),
			imageBytes: imageBytes,
			readBytes: p -> {
				var bytes = imageBytes(p);
				return bytes == null ? null : haxe.crypto.Base64.encode(bytes);
			},
			readFile: p -> {
				var full = projectPath(p);
				buffers.exists(full) ? buffers.get(full).get() : sys.FileSystem.exists(full) && !sys.FileSystem.isDirectory(full) ? sys.io.File.getContent(full) : null;
			},
			activeFile: () -> realFile(active.get()),
			root: () -> props.display.cwd,
			openFile: p -> openFile(projectPath(p)),
			focusView: (file, root) -> {
				var id = TAB + file + "#" + root;
				if (open.get().indexOf(id) >= 0) active.set(id);
			},
			openExternal: url -> {
				var result = switch Sys.systemName() {
					case "Mac": Sys.command("open", [url]);
					case "Windows": Sys.command("rundll32", ["url.dll,FileProtocolHandler", url]);
					case _: Sys.command("xdg-open", [url]);
				};
				if (result != 0) throw "Cannot open external link";
			},
			writeFile: (p, text) -> {
				var full = projectPath(p);
				var b = buffers.get(full), before = b != null ? b.get() : sys.FileSystem.exists(full) ? sys.io.File.getContent(full) : "";
				localHistory.record(full, before, text, null, "Extension edit");
				sys.io.File.saveContent(full, text);
				localHistory.saved(full, text, null);
				if (b != null)
					b.set(text);
				dirty.set([for (d in dirty.get()) if (d != full) d]);
				refreshExplorer();
			},
			notify: (id, title, message, kind) -> Toaster.show({title:title, description:message,
				variant:kind == "error" ? Destructive : kind == "warning" ? Warning : kind == "success" ? Success : Default,
				duration:kind == "error" ? 10 : 5,
				action:{label:"Show Output", run:() -> {
					outputChannel.set("ext:" + id);
					refreshExtensionOutput();
					showPanel("console");
					ashui.animation.AnimationScheduler.main.after(.01, () -> revealExtensionOutput());
				}}}),
			replay: replayOf
		};

	/** What a hook reports about the present, told to an extension when it starts listening for it. */
	function replayOf(name:String):Dynamic
		return switch name {
			case "active.changed": ({path: realFile(active.get())} : Dynamic);
			case "project.opened": ({root: props.display.cwd} : Dynamic);
			case _: null;
		};

	/** Writes every edited buffer to its file: a build reads the files, so it should see them as they are in the editor. */
	public function saveAll():Void {
		for (file in dirty.get()) {
			sys.io.File.saveContent(file, buffer(file).get());
			localHistory.saved(file, buffer(file).get(), documents.exists(file) ? DocumentHistory.snapshot(documents.get(file)) : null);
			var studio = studios.get(file);
			if (studio != null && !studio.live.get())
				studio.reload();
			emit("file.saved", {path: file});
			var client = languageServers.client(file);
			if (client != null) { languageServers.sync(file, buffer(file).get()); client.saved(file); }
		}
		if (dirty.get().length > 0)
			dirty.set([]);
	}

	/** Saves what is edited, then builds the project and runs it. */
	public function run():Void {
		// Run is Continue while the extension is stopped.
		var d = debugger();
		if (d != null && d.stopped.get() != null) {
			d.resume("continue");
			return;
		}
		saveAll();
		if (extension != null || isExtension(active.get())) {
			(extension != null ? extensionStudio() : studioOf(active.get())).reload();
			showPanel("extension");
			return;
		}
		runner.start();
		showPanel("console");
		poll();
	}

	/** While a build or run is going, looks at it ten times a second; a window that is otherwise still draws no frames to do it from. */
	function poll():Void {
		tick();
		if (runner.active())
			ashui.animation.AnimationScheduler.main.after(.1, poll);
	}

	public function stopRun():Void
		runner.stop();

	/** Moves a build or run along and shows what it printed. */
	public function tick():Void {
		if (runner == null)
			return;
		runner.tick();
		if (runner.revision == seen)
			return;
		seen = runner.revision;
		outputJobs.request("build", [runner.console], null);
		if (!outputScheduled) { outputScheduled = true; ashui.animation.AnimationScheduler.main.after(.016, pollOutput); }
		runState.set(runner.state);
		if (runner.problems != lastBuild) {
			lastBuild = runner.problems;
			problems.set([for (p in problems.get()) if (!Lambda.exists(runner.problems, b -> b.file == p.file)) p].concat(runner.problems));
			if (runner.state == "failed")
				showPanel("problems");
		}
	}

	/** Asks the compiler what is wrong with `file` as it is in the editor. */
	public function check(file:String):Void {
		if (!isVirtual(file) && languageServers != null && languageServers.client(file) != null) {
			diagnosticJobs.cancel(file);
			languageServers.sync(file, buffer(file).get());
			return;
		}
		if (isVirtual(file) || !StringTools.endsWith(file, ".hx"))
			return;
		diagnosticJobs.request(file, buffer(file).get());
		wakeDiagnostics();
	}

	function wakeDiagnostics():Void {
		if (gone || diagnosticsScheduled) return;
		diagnosticsScheduled = true;
		ashui.animation.AnimationScheduler.main.after(.03, pollDiagnostics);
	}

	function pollDiagnostics():Void {
		if (gone) return;
		for (result in diagnosticJobs.tick()) {
			var source = buffers.get(result.file);
			var valid = result.lsp ? languageServers.client(result.file) != null && (source == null || source.get() == result.text)
				: languageServers.client(result.file) == null && source != null && source.get() == result.text && open.get().indexOf(result.file) >= 0;
			var current = problems.get();
			if (valid && !LspProtocol.sameDiagnostics([for (p in current) if (p.file == result.file) p], result.problems))
				problems.set([for (p in current) if (p.file != result.file) p].concat(result.problems));
		}
		diagnosticsScheduled = diagnosticJobs.busy();
		if (diagnosticsScheduled) ashui.animation.AnimationScheduler.main.after(.03, pollDiagnostics);
	}

	/** Runs the command whose key was pressed: the bindings say which, and the Settings page changes them. */
	function key(e:KeyEvent):Void {
		if (e.defaultPrevented)
			return;
		var chord = Chord.ofEvent(e.key, e.shift, e.control, e.alt, e.superKey);
		if (chord == null)
			return;
		var id = bindings.commandFor(chord);
		var action = id == null ? null : Lambda.find(commandList, a -> a.id == id);
		if (action == null)
			return;
		// The keys of the file commands are the editor's own, copy and paste among them: they are the Explorer's only while it has the keyboard.
		if (Keymaps.fileCommands.indexOf(id) >= 0 && !explorerFocused())
			return;
		action.run();
		e.preventDefault();
	}

	/** Whether the keyboard is on the Explorer or something in it. */
	function explorerFocused():Bool {
		var found = ashui.css.Css.query(tree, this.node.id, "#rayde-files"), at = ashui.input.Focus.of(tree);
		if (found.length == 0 || at == null)
			return false;
		return at.node.id == found[0] || tree.ancestors(at.node.id).indexOf(found[0]) >= 0;
	}

	function runtime():String
		return props.runtime == null ? "ash" : props.runtime;

	function render():Element {
		extension = props.extension;
		runner = new Runner(props.display);
		diagnosticJobs = new DiagnosticJobs(props.display);
		languageServers = new LanguageServers(props.display.cwd);
		languageServers.onWake = () -> wakeLanguages();
		languageServers.onStatus = () -> { if (!gone) languageStatusRevision.set(languageStatusRevision.get() + 1); };
		languageServers.onDocumentActivity = file -> { if (!gone && file == active.get()) languageActivityRevision.set(languageActivityRevision.get() + 1); };
		languageServers.onDiagnostics = value -> {
			var file = LspProtocol.path(value.uri);
			if (file == null) return;
			var source = buffers.get(file);
			diagnosticJobs.publish(file, source == null ? null : source.get(), value);
			wakeDiagnostics();
		};
		languageServers.onChanged = () -> {
			if (gone) return;
			languageRevision.set(languageRevision.get() + 1);
			for (file in open.get()) if (!isVirtual(file) && (file == active.get() || buffers.exists(file))) check(file);
			refreshExplorer();
			wakeLanguages();
		};
		terminalSettings = Settings.read(props.display.cwd);
		appearance = Appearance.read(props.display.cwd);
		chrome = props.chrome != null ? props.chrome : new WindowChrome();
		assist = new CodeAssist(props.display, languageServers);
		if (props.theme != null)
			themeStudio = makeThemeStudio(props.theme.file);
		windowStyle.set(WindowControls.styleFor(appearance.windowControls));
		bindings = KeyBindings.read(props.display.cwd, Sys.systemName() == "Mac");
		libraries = new LibraryManager(props.display.cwd);
		startExtensions();
		containers = makeContainers();
		commandList = commands();
		refreshFileIndex();
		refreshShortcuts();
		loadRecent();
		new ashui.reactive.Watch(() -> { open.get(); dirty.get(); 0; }, _ -> releaseClosedDocuments(), (_, _) -> false);
		new ashui.reactive.Watch(() -> problemsHeight.get(), h -> if (h > 40) panelHeight = h);
		new ashui.reactive.Watch(() -> { open.get(); active.get(); 0; }, _ -> {
			if (sessionReady) workspaceSession.save(sessionSnapshot());
		}, (_, _) -> false);
		new ashui.reactive.Watch(() -> active.get(), file -> {
			activeStudio.set(extension != null ? extensionStudio() : studios.get(file));
			emit("active.changed", {path: realFile(file)});
		});
		new ashui.reactive.Watch(() -> { active.get(); sideView.get(); 0; }, _ -> ashui.core.Memory.collectSoon(), (_, _) -> false);
		new ashui.reactive.Watch(() -> panelShown.get(), shown -> markPanel(shown));
		new ashui.reactive.Watch(() -> panelShown.get() && bottom.get() == "console", visible -> {
			if (visible && extensionOutputDirty) refreshExtensionOutput();
		});
		// The controls go grey while another window is in front.
		new ashui.reactive.Watch(() -> ashui.input.WindowState.active.get(), on -> chrome.focused.set(on));
		// The terminal starts when its tab is first in view, not when RayDE does.
		new ashui.reactive.Watch(() -> {
			bottom.get();
			panelShown.get();
			0;
		}, _ -> if (bottom.get() == "terminal" && panelShown.get())
			ensureTerminal(), (_, _) -> false);
		Owner.onCleanup(() -> {
			gone = true;
			if (languagePollTimer != null) languagePollTimer.cancel();
			languagePollTimer = null;
			languagesScheduled = false;
			if (workspaceSession != null) workspaceSession.close(sessionReady ? sessionSnapshot() : null);
			fileIndex.dispose();
			localHistory.dispose();
			for (syntax in nativeSyntax) if (syntax != null) syntax.dispose();
			nativeSyntax.clear();
			diagnosticJobs.dispose();
			outputJobs.dispose();
			runner.stop();
			languageServers.dispose();
			for (s in sessions)
				s.terminal.close();
			// An extension's host is a process of its own, which goes with the workbench.
			extensionManager.dispose();
			for (studio in studios)
				studio.dispose();
			if (themeStudio != null)
				themeStudio.dispose();
		});
		new ashui.reactive.Watch(() -> {
			active.get();
			settingsCategory.get();
			folderStates.get();
			for (open in folderOpen)
				open.get();
			treeSelected.get();
			0;
		}, _ -> keepSelection(), (_, _) -> false);
		var window = <div id="rayde-window" widthPercent={1} heightPercent={1} class="flex flex-col bg-background text-text-primary relative">
			${titleBar()}
			<div class="flex flex-1 min-h-0 px-2">
				<for {revision in [layoutRevision.get()]}>${columns()}</for>
			</div>
			${statusBar()}
			<prompt request={prompt}/>
			<for {direction in (chrome.resizable() ? EDGES : [])}>${edge(direction)}</for>
			<command-center opened={quickOpen} request={centerRequest} anchor={pill} files={recentFiles} refreshFiles={refreshFileIndex} root={props.display.cwd} actions={commandList} tasks={taskChoices}
				onOpenFile={path -> openFile(path)} onLine={goToLine}/>
			<toaster id="rayde-toaster"/>
		</div>;
		// A window of its own, not filling the screen, has rounded corners (but Windows's) and, where the system draws no frame, an outline.
		// They are on a card inside the root, which is the whole of what the window draws and cannot be clipped.
		var root = <div id="rayde" widthPercent={1} heightPercent={1} class="flex flex-col text-text-primary" onKeyDown={key}>{window}</div>;
		var identity = ashui.css.Identity.of(window.tree, window.node.id);
		// A theme's own stylesheet is written under this, so it applies only while the theme is in use.
		ashui.css.Identity.of(root.tree, root.node.id).bindAttribute("data-theme", Computed.make(() -> Theming.current.get()));
		ashui.css.Identity.of(root.tree, root.node.id).bindBooleanAttribute("data-sans", Computed.make(() -> Theming.ownSans.get()));
		identity.bindBooleanAttribute("data-round", Computed.make(() -> chrome.resizable() && windowStyle.get() != "windows"));
		identity.bindBooleanAttribute("data-outline", Computed.make(() -> chrome.resizable() && windowStyle.get() != "macos"));
		return root;
	}

	/** The side panel, the editor with the bottom panel under it, and the right side bar when an extension view is there. */
	function columns():Element {
		var main = <resizable-panel minSize={320}>
			<resizable ref={rowsRef} id="rayde-rows" direction="vertical" class="flex-1 min-h-0">
				<resizable-panel minSize={160}>${editorCard()}</resizable-panel>
				<resizable-panel size={problemsHeight} minSize={0} maxSize={480}>${bottomCard()}</resizable-panel>
			</resizable>
		</resizable-panel>;
		var hasSecondary = Lambda.exists(containers, c -> c.location == "secondary");
		if (hasSecondary)
			return <resizable id="rayde-columns" class="flex-1 min-h-0">
				<resizable-panel size={treeWidth} minSize={ACTIVITY} maxSize={ACTIVITY + 480}>${sideBar()}</resizable-panel>
				{main}
				<resizable-panel size={secondaryWidth} minSize={0} maxSize={560}>${secondaryBar()}</resizable-panel>
			</resizable>;
		return <resizable id="rayde-columns" class="flex-1 min-h-0">
			<resizable-panel size={treeWidth} minSize={ACTIVITY} maxSize={ACTIVITY + 480}>${sideBar()}</resizable-panel>
			{main}
		</resizable>;
	}

	/** The project in a pill in the middle, which opens the command center, and the window's controls at one end; the bar moves the window. */
	function titleBar():Element {
		var hint = Sys.systemName() == "Mac" ? "⌘P" : "Ctrl+P";
		pill = <div id="rayde-project" class="rayde-pill flex items-center gap-2 px-3 cursor-pointer" width={420} height={26} onPointerDown={e -> e.stopPropagation()} onClick={_ -> if (quickOpen.get()) quickOpen.set(false) else openCenter()}>
			<icon document={Icons.FOLDER_3_LINE} class="rayde-pill-icon size-3.5"/>
			<text class="text-xs flex-1">${props.name}</text>
			<text class="rayde-pill-hint text-xs">${hint}</text>
		</div>;
		return <div id="rayde-bar" class="flex items-center shrink-0" height={40} onPointerDown={barPress}>
			<for {style in [windowStyle.get()]}>${barEnd(style, true)}</for>
			<div class="flex-1"/>
			<tooltip label={"Search files and commands in " + props.display.cwd} side="bottom">{pill}</tooltip>
			<div class="flex-1"/>
			<for {style in [windowStyle.get()]}>${barEnd(style, false)}</for>
		</div>;
	}

	/** One end of the bar: the controls where the style puts them, and on the other end a space of the same width, so the pill stays in the middle. */
	function barEnd(style:String, leftEnd:Bool):Element {
		if (WindowControls.onLeft(style) == leftEnd)
			return <window-controls style={style} chrome={chrome}/>;
		return <div class="shrink-0" width={WindowControls.width(style)}/>;
	}

	/** A press on the bar: a double click maximizes the window, and anything else on it moves the window. */
	function barPress(e:ashui.input.Events.PointerEvent):Void {
		if (e.button == null || !e.button.match(Left))
			return;
		if (e.clickCount >= 2)
			chrome.toggleMaximize();
		else
			chrome.drag();
	}

	/** The edges and corners that resize the window, in the order they are laid over the page. */
	static final EDGES = ["North", "South", "East", "West", "NorthEast", "NorthWest", "SouthEast", "SouthWest"];

	/** One of the edges: an invisible strip along a side or a square at a corner, which starts a resize from there. */
	function edge(direction:String):Element {
		var el = <div class="rayde-edge" onPointerDown={e -> if (e.button != null && e.button.match(Left)) {
			e.stopPropagation();
			chrome.resize(direction);
		}}/>;
		var place = switch direction {
			case "North": "n";
			case "South": "s";
			case "East": "e";
			case "West": "w";
			case "NorthEast": "ne";
			case "NorthWest": "nw";
			case "SouthEast": "se";
			case _: "sw";
		};
		ashui.css.Identity.of(el.tree, el.node.id).setClasses(["rayde-edge", "rayde-edge-" + place]);
		return el;
	}

	/** The side panel: the activity bar and the Explorer beside it, in one card. */
	function sideBar():Element {
		// Primitive keys keep the mounted view while a width change leaves it visible.
		return <div id="rayde-side" class="rayde-card panel flex flex-1 min-h-0">
			${activityBar()}
			<for {shown in [explorerShown.get()]}>
				<for {build in [buildRevision.get()]}>
					<for {view in [sideView.get()]}>${sideBody(shown, view)}</for>
				</for>
			</for>
		</div>;
	}

	/** What fills the side panel beside the activity bar: the Explorer, or the view of an extension that took its place. */
	function sideBody(shown:Bool, view:String):Element {
		if (!shown)
			return <div/>;
		var c = Lambda.find(containers, c -> c.id == view && c.location == "sidebar");
		return c == null ? explorer(shown) : extensionBody(c, "rayde-explorer");
	}

	/** An extension's view in the part of the layout it was given, under its own heading. */
	function extensionBody(c:Container, style:String):Element {
		var studio = studios.get(c.extension.mainPath());
		if (studio == null)
			return <div/>;
		return <div id={"rayde-view-" + c.id} class="rayde-explorer flex flex-col flex-1 min-w-0 min-h-0">
			<studio-view studio={studio} framed={false} view={c.view} onMocks={() -> openMocks(studio)} onConsole={() -> showPanel("extension")}/>
		</div>;
	}

	/** The right side bar: the extension views that asked to be there, one above the other. */
	function secondaryBar():Element {
		var here = [for (c in containers) if (c.location == "secondary") c];
		if (here.length == 0)
			return <div/>;
		return <div id="rayde-secondary" class="rayde-card panel flex flex-col flex-1 min-h-0">{[for (c in here) extensionBody(c, "")]}</div>;
	}

	/** Views down the left edge of the side panel; the Explorer is the one there is, and its icon folds the Explorer away and brings it back. */
	function activityBar():Element
		return <div id="rayde-activity" class="flex flex-col items-center shrink-0 gap-1 py-2" width={ACTIVITY}>
			<for {shown in [explorerShown.get()]}>
				<for {view in [sideView.get()]}>${containerItems(shown, view)}</for>
			</for>
			<div class="flex-1"/>
			<for {on in [active.get() == SETTINGS]}>${settingsItem(on)}</for>
		</div>;

	function settingsItem(on:Bool):Element {
		var item = <div id="rayde-activity-settings" class="rayde-activity-item flex" onClick={_ -> openSettings()}>
			<icon document={Icons.SETTINGS_3_LINE} class="size-5"/>
		</div>;
		if (on)
			ashui.css.Identity.of(item.tree, item.node.id).setAttribute("data-on", "");
		return <tooltip label="Settings" side="right">{item}</tooltip>;
	}

	/** The Explorer's icon and one for each extension view, which an extension that is in the sidebar swaps with the Explorer. */
	function containerItems(shown:Bool, view:String):Element {
		var items:Array<Element> = [activityItem("rayde-activity-explorer", "Explorer", Icons.FOLDERS_LINE, shown && view == "explorer", chooseExplorer)];
		for (c in containers) if (c.location != "explorer") {
			// Only the view the side panel shows is selected; a view in another part of the layout is toggled from here but is not what the activity bar is showing.
			var on = c.location == "sidebar" && shown && view == c.id;
			items.push(activityItem("rayde-activity-" + c.id, c.title, c.icon, on, () -> chooseContainer(c)));
		}
		return <div class="flex flex-col items-center gap-1">{items}</div>;
	}

	function activityItem(id:String, label:String, icon:ashui.svg.SvgDocument, on:Bool, choose:Void->Void):Element {
		var item = <div id={id} class="rayde-activity-item flex" onClick={_ -> choose()}>
			<icon document={icon} class="size-5"/>
		</div>;
		if (on)
			ashui.css.Identity.of(item.tree, item.node.id).setAttribute("data-on", "");
		return <tooltip label={label} side="right">{item}</tooltip>;
	}

	/** The Explorer's icon: it takes the side panel back from an extension, or, when it is there already, folds it away. */
	function chooseExplorer():Void {
		if (sideView.get() == "explorer" || !explorerShown.get()) {
			sideView.set("explorer");
			toggleExplorer();
			return;
		}
		sideView.set("explorer");
	}

	/** An extension's icon: shows its view where it was put, or folds that away when it is showing. */
	public function chooseContainer(c:Container):Void {
		extensionManager.view(c.extension.id, c.view.id);
		switch c.location {
			case "explorer":
				sideView.set("explorer");
				if (!explorerShown.get()) treeWidth.set(ACTIVITY + EXPLORER_WIDTH);
			case "sidebar":
				if (sideView.get() == c.id && explorerShown.get())
					treeWidth.set(ACTIVITY);
				else {
					sideView.set(c.id);
					if (!explorerShown.get())
						treeWidth.set(ACTIVITY + EXPLORER_WIDTH);
				}
			case "secondary":
				secondaryWidth.set(secondaryWidth.get() > 0 ? 0 : SECONDARY_WIDTH);
			case "panel":
				if (panelShown.get() && bottom.get() == "ext-" + c.id)
					closePanel();
				else
					showPanel("ext-" + c.id);
			case _:
				openFile(containerTab(c));
		}
	}

	/** What decides where the extension's views are and how their headers look: when it changes, the layout is made again. */
	static function layoutKey(m:Manifest):String
		return haxe.Json.stringify(m.views);

	/** The form changed the extension's config, which has been read again: the Studio and, if the view moved or looks different, the layout follow. */
	function extensionChanged(m:Manifest):Void {
		var before = extension == null ? "" : layoutKey(extension), previousMain = extension == null ? null : extension.mainPath();
		var studio = previousMain == null ? null : studios.get(previousMain);
		var moved = previousMain != null && previousMain != m.mainPath();
		if (moved && studio != null) {
			syncTabs(studio, []);
			studio.stop();
			studios.remove(previousMain);
			problems.set([for (p in problems.get()) if (p.file != previousMain) p]);
		}
		extension = m;
		var entry = extensionManager.find(m.id);
		if (entry != null) entry.connection.useManifest(m);
		if (studio != null) {
			studio.useManifest(m);
			if (moved) { studios.set(m.mainPath(), studio); studio.reload(); }
		}
		commandList.splice(0, commandList.length);
		for (a in commands())
			commandList.push(a);
		refreshExtensionBindings();
		refreshShortcuts();
		bindingsRevision.set(bindingsRevision.get() + 1);
		if (layoutKey(m) == before && !moved)
			return;
		containers = makeContainers();
		if (!Lambda.exists(containers, c -> c.id == sideView.get() && c.location == "sidebar")) {
			var first = Lambda.find(containers, c -> c.location == "sidebar");
			sideView.set(first == null ? "explorer" : first.id);
		}
		layoutRevision.set(layoutRevision.get() + 1);
	}

	function makeContainers():Array<Container> {
		var out:Array<Container> = [];
		for (e in extensionManager.enabled()) {
			var m = e.connection.manifest;
			for (v in m.views) out.push({id: extension != null && m.id == extension.id ? (v.id == "main" ? "ext" : "ext-" + v.id) : "ext-" + m.id + "-" + v.id,
				title: v.title, icon: ViewIcons.ofView(m, v), location: v.location, view: v, extension: m});
		}
		return out;
	}

	/** The Studio of this project's extension: its main script, run with the project's config. */
	function extensionStudio():Null<Studio>
		return extension == null ? null : studioOf(extension.mainPath());

	function explorer(shown:Bool):Element {
		if (!shown)
			return <div/>;
		var files = () -> {
			var root = tagged(<tree-item value={props.display.cwd} label={props.name} icon={Icons.FOLDER_OPEN_LINE} expanded={folderState(props.display.cwd, true)}>${buildRow()}{folders()}</tree-item>, props.display.cwd);
			return <context-menu ref={explorerMenu} id="rayde-explorer-menu">
					<context-menu-trigger id="rayde-explorer-trigger">
						<div id="rayde-explorer-scroll" class="flex flex-col flex-1 min-h-0 overflow-auto pr-2 pb-2" onPointerDown={explorerPress}>
							<tree-view id="rayde-tree" selected={treeSelected} onSelect={v -> if (Manifest.isManifest(v)) openSettings("extension") else if (ThemeFile.isThemeFile(v)) openThemeStudio() else if (isSource(v)) openFile(v) else if (v == props.display.hxml) openBuild()}>${root}</tree-view>
						</div>
					</context-menu-trigger>
					<context-menu-content id="rayde-explorer-menu-content"><for {state in [{target: menuTarget.get(), keys: bindingsRevision.get(), held: clipboardRevision.get()}]}>${explorerItems(state.target)}</for></context-menu-content>
				</context-menu>;
		};
		var sections:Array<Element> = [new ResizablePanel({id:"rayde-explorer-panel-files", size:explorerFilesSize, minSize:60}, [files()])];
		sections.push(explorerSection("outline", false, 180).panel("Outline", () ->
			<explorer-outline display={props.display} languages={languageServers} revision={() -> buildRevision.get() + languageRevision.get()} file={() -> realFile(active.get())} text={file -> buffer(file).get()} onSelect={goTo}/>, []));
		var contributed = [for (c in containers) if (c.location == "explorer") c];
		var gitTimeline = Lambda.find(contributed, c -> c.view.id == "timeline");
		sections.push(explorerSection("timeline", false, 180).panel("Timeline", () ->
			<div class="flex flex-col flex-1 min-h-0">
			<local-timeline history={localHistory} revision={historyRevision} file={() -> { var file = realFile(active.get()); return file != null && ImagePreview.isRaster(file) ? null : file; }} text={file -> buffer(file).get()} onPreview={previewHistory}/>
				{gitTimeline == null ? <text class="text-xs text-text-secondary px-3 py-2">Enable Git for commit history</text> : explorerView(gitTimeline)}
			</div>, gitTimeline == null ? [] : explorerTools(gitTimeline)));

		for (c in contributed) if (c != gitTimeline)
			sections.push(explorerSection(c.view.id, false, 160).panel(c.title, () -> explorerView(c), explorerTools(c)));

		sections.push(explorerSection("dependencies", false, 160).panel("Dependencies", () ->
			<for {revision in [dependenciesRevision.get()]}><explorer-dependencies root={props.display.cwd} args={props.display.args} onOpen={openFile}/></for>, [
			<tooltip label="Refresh dependencies" side="bottom"><button id="rayde-dependencies-refresh" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> dependenciesRevision.set(dependenciesRevision.get() + 1)}><icon document={Icons.REFRESH_LINE} class="size-3"/></button></tooltip>,
			<tooltip label="Manage libraries" side="bottom"><button id="rayde-dependencies-settings" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> openSettings("libraries")}><icon document={Icons.SETTINGS_3_LINE} class="size-3"/></button></tooltip>
		]));
		return <div id="rayde-files" class="rayde-explorer flex flex-col flex-1 min-w-0 min-h-0">
			<div class="flex items-center px-3 shrink-0" height={36}><text class="rayde-heading">Explorer</text></div>
			<resizable id="rayde-explorer-sections" direction="vertical" class="flex-1 min-h-0">{sections}</resizable>
		</div>;
	}

	function explorerTools(c:Container):Array<Element>
		return [for (t in c.view.tools) <tooltip label={t.title} side="bottom"><button id={"rayde-tool-" + t.id} variant={Ghost} size={Icon} class="rayde-panel-button"
			onClick={_ -> studioOf(c.extension.mainPath()).tool(t.id)}><icon document={ViewIcons.tool(c.extension, t)} class="size-3"/></button></tooltip>];

	function explorerView(c:Container):Element {
		extensionManager.view(c.extension.id, c.view.id);
		var studio = studioOf(c.extension.mainPath());
		return <studio-view studio={studio} framed={false} header={false} view={c.view} onMocks={() -> openMocks(studio)} onConsole={() -> showPanel("extension")}/>;
	}

	function explorerSection(id:String, open:Bool, size:Float):ExplorerSection {
		if (!explorerSections.exists(id)) explorerSections.set(id, new ExplorerSection(id, open, size));
		return explorerSections.get(id);
	}

	/** Marks a row of the tree with the path it stands for, so a press on it can be traced to the file. */
	function tagged(item:Element, path:String):Element {
		ashui.css.Identity.of(item.tree, item.node.id).setAttribute("data-path", path);
		return item;
	}

	/** The path of the row of the tree under a point, or null. */
	function rowAt(x:Float, y:Float):Null<String> {
		for (hit in tree.hitTest(x, y))
			for (id in [hit.id].concat(tree.ancestors(hit.id))) {
				var identity = ashui.css.Identity.of(tree, id);
				var path = identity == null ? null : identity.attribute("data-path");
				if (path != null)
					return path;
			}
		return null;
	}

	/** A secondary press on the tree opens the menu for the row under it, after the menu has been given that row's items. */
	function explorerPress(e:ashui.input.Events.PointerEvent):Void {
		if (e.button == null || !e.button.match(Right))
			return;
		// The trigger around the tree would open the menu at once, on the last row's items; it opens once this one's are in.
		e.stopPropagation();
		e.preventDefault();
		var path = rowAt(e.x, e.y);
		menuTarget.set(path == null ? props.display.cwd : path);
		var x = e.x, y = e.y;
		ashui.animation.AnimationScheduler.main.after(.02, () -> {
			var menu = explorerMenu.get();
			if (menu != null)
				menu.openAt(x, y);
		});
	}

	/** The id of a menu item, from its label: `New File…` is `rayde-explorer-new-file`. */
	static function menuId(label:String):String
		return "rayde-explorer-" + [for (w in label.split(" ")) w.toLowerCase().replace("…", "")].join("-");

	function menuItem(label:String, command:Null<String>, run:Void->Void, enabled = true, ?icon:ashui.svg.SvgDocument):Element {
		var keys = command == null ? null : bindings.label(command);
		var item = <context-menu-item id={menuId(label)} shortcut={keys} disabled={!enabled} onSelect={run}>${label}</context-menu-item>;
		// Icons belong to the menu row, outside its label's text flow.
		if (icon != null) item.appendChild(<icon document={icon} class="size-4 shrink-0 text-text-secondary"/>);
		return item;
	}

	function dangerItem(label:String, command:Null<String>, run:Void->Void):Element {
		var keys = command == null ? null : bindings.label(command);
		return <context-menu-item id={menuId(label)} shortcut={keys} destructive={true} onSelect={run}>${label}</context-menu-item>;
	}

	/** The items of the Explorer's menu for a file, a folder or the project's own folder. */
	function explorerItems(path:String):Element {
		var folder = path != "" && sys.FileSystem.exists(path) && sys.FileSystem.isDirectory(path), top = path == props.display.cwd;
		var items:Array<Element> = [];
		var contributed = contributedMenu("explorer/context", path, folder ? "folder" : "file");
		if (!folder && path != "")
			items.push(menuItem("Open", null, () -> if (isSource(path)) openFile(path) else if (ThemeFile.isThemeFile(path)) openThemeStudio() else if (Manifest.isManifest(path)) openSettings("extension")));
		if (!folder && ImagePreview.isSvg(path)) {
			items.push(menuItem("Open Preview", null, () -> { imageTextMode(path).set(false); openFile(path); }, true, Icons.IMAGE_LINE));
			items.push(menuItem("Open in Editor", null, () -> { imageTextMode(path).set(true); openFile(path); }, true, Icons.CODE_S_SLASH_LINE));
		}
		if (folder) {
			items.push(menuItem("New File…", "newfile", () -> askCreate(path, false)));
			items.push(menuItem("New Folder…", "newfolder", () -> askCreate(path, true)));
		}
		if (contributed.length > 0) {
			if (items.length > 0)
				items.push(<context-menu-separator/>);
			for (entry in contributed) {
				var c = entry.item, m = entry.extension;
				items.push(menuItem(c.title, extensionKey(m.id, c.command), () -> runExtensionCommand(m.id, c.command, path), true, ViewIcons.named(m, c.icon)));
			}
		}
		if (items.length > 0)
			items.push(<context-menu-separator/>);
		if (!top) {
			items.push(menuItem("Cut", "filecut", () -> copyFile(path, true)));
			items.push(menuItem("Copy", "filecopy", () -> copyFile(path, false)));
		}
		items.push(menuItem("Paste", "filepaste", () -> pasteFiles(folder ? path : haxe.io.Path.directory(path)), fileClipboard != null));
		if (!top)
			items.push(menuItem("Duplicate", "fileduplicate", () -> duplicateFile(path)));
		items.push(<context-menu-separator/>);
		items.push(menuItem("Copy Path", "filecopypath", () -> ashui.input.Clipboard.setText(path)));
		items.push(menuItem("Copy Relative Path", "filecopyrelative", () -> ashui.input.Clipboard.setText(FileOps.relative(props.display.cwd, path))));
		items.push(menuItem(Sys.systemName() == "Mac" ? "Reveal in Finder" : "Reveal in File Manager", "filereveal", () -> FileOps.reveal(path)));
		if (!top) {
			items.push(<context-menu-separator/>);
			items.push(menuItem("Rename…", "filerename", () -> askRename(path)));
			items.push(dangerItem("Delete…", "filedelete", () -> askDelete(path)));
		}
		items.push(<context-menu-separator/>);
		items.push(menuItem("Refresh", null, refreshExplorer));
		return <div class="flex flex-col">{items}</div>;
	}

	/** Files cut or copied in the Explorer, waiting to be pasted. */
	var fileClipboard:Null<{paths:Array<String>, cut:Bool}>;

	function copyFile(path:String, cut:Bool):Void {
		fileClipboard = {paths: [path], cut: cut};
		clipboardRevision.set(clipboardRevision.get() + 1);
	}

	/** The file or closed folder the Explorer has selected, the one the file commands act on; not the project's own folder. */
	function selectedPath():Null<String> {
		var path = treeSelected.get();
		return path == null || path == "" || path == props.display.cwd || isVirtual(path) ? null : path;
	}

	function withSelected(run:String->Void):Void {
		var path = selectedPath();
		if (path != null)
			run(path);
	}

	/** Where a new file goes by key: in the selected folder, beside the selected file, or in the project's own folder. */
	function selectedFolder():String {
		var path = selectedPath();
		if (path == null)
			return props.display.cwd;
		return sys.FileSystem.exists(path) && sys.FileSystem.isDirectory(path) ? path : haxe.io.Path.directory(path);
	}

	/** Puts what was cut or copied into `dir`: a copy takes a free name, and what was cut is moved, its tabs with it. */
	function pasteFiles(dir:String):Void {
		var held = fileClipboard;
		if (held == null)
			return;
		try {
			for (p in held.paths) {
				if (!sys.FileSystem.exists(p))
					continue;
				if (held.cut) {
					var to = FileOps.move(props.display.cwd, p, dir);
					if (to != p)
						moveTabs(p, to);
				} else
					FileOps.copy(props.display.cwd, p, dir, FileOps.uniqueName(dir, haxe.io.Path.withoutDirectory(haxe.io.Path.removeTrailingSlashes(p))));
			}
			if (held.cut) {
				fileClipboard = null;
				clipboardRevision.set(clipboardRevision.get() + 1);
			}
			folderState(dir, true).set(true);
			refreshExplorer();
		} catch (e:Dynamic)
			say(Std.string(e));
	}

	function duplicateFile(path:String):Void {
		try {
			FileOps.duplicate(props.display.cwd, path);
			refreshExplorer();
		} catch (e:Dynamic)
			say(Std.string(e));
	}

	/** Builds the tree again from the files as they are. */
	public function refreshExplorer():Void {
		refreshFileIndex();
		buildRevision.set(buildRevision.get() + 1);
	}

	function askCreate(dir:String, folder:Bool):Void
		prompt.set({
			title: folder ? "New Folder" : "New File",
			description: "Create in " + (dir == props.display.cwd ? props.name : FileOps.relative(props.display.cwd, dir)),
			action: "Create",
			hasInput: true,
			placeholder: folder ? "Folder name" : "File name",
			check: FileOps.invalid,
			accept: name -> {
				var made = folder ? FileOps.createFolder(props.display.cwd, dir, name) : FileOps.createFile(props.display.cwd, dir, name);
				folderState(dir, true).set(true);
				refreshExplorer();
				if (!folder)
					openFile(made);
			}
		});

	function askRename(path:String):Void
		prompt.set({
			title: "Rename",
			description: FileOps.relative(props.display.cwd, path),
			action: "Rename",
			hasInput: true,
			value: haxe.io.Path.withoutDirectory(haxe.io.Path.removeTrailingSlashes(path)),
			check: FileOps.invalid,
			accept: name -> {
				var to = FileOps.rename(props.display.cwd, path, name);
				moveTabs(path, to);
				refreshExplorer();
			}
		});

	function askDelete(path:String):Void
		prompt.set({
			title: "Delete",
			description: "Permanently delete " + FileOps.summary(path) + ". This cannot be undone.",
			action: "Delete",
			destructive: true,
			accept: _ -> {
				for (f in FileOps.under(open.get(), path))
					closeFile(f);
				FileOps.delete(props.display.cwd, path);
				for (f in FileOps.under([for (k in buffers.keys()) k], path))
					buffers.remove(f);
				dirty.set([for (f in dirty.get()) if (FileOps.under([f], path).length == 0) f]);
				refreshExplorer();
			}
		});

	/** A file or folder was renamed: the tabs, buffers and edits under it follow it to the new path. */
	function moveTabs(from:String, to:String):Void {
		localHistory.move(from, to);
		for (entry in historyTabs) if (entry.file == from || entry.file.startsWith(haxe.io.Path.addTrailingSlash(from))) entry.file = to + entry.file.substr(from.length);
		var moved = FileOps.moved(open.get(), from, to);
		for (old => now in FileOps.moved([for (k in nativeSyntax.keys()) k], from, to)) {
			var syntax = nativeSyntax.get(old);
			if (syntax != null) syntax.dispose();
			nativeSyntax.remove(old);
		}
		for (old => now in FileOps.moved([for (k in buffers.keys()) k], from, to)) {
			buffers.set(now, buffers.get(old));
			buffers.remove(old);
		}
		for (old => now in FileOps.moved([for (k in documents.keys()) k], from, to)) {
			documents.set(now, documents.get(old));
			documents.remove(old);
		}
		for (old => now in moved) {
			editorRefs.remove(old);
			var studio = studios.get(old);
			if (studio != null) {
				studio.dispose();
				studios.remove(old);
			}
		}
		var remap = (f:String) -> moved.exists(f) ? moved.get(f) : f;
		var front = active.get();
		open.set([for (f in open.get()) remap(f)]);
		dirty.set([for (f in dirty.get()) FileOps.moved([f], from, to).exists(f) ? FileOps.moved([f], from, to).get(f) : f]);
		active.set(remap(front));
	}

	/** Whether the folder `dir` shows its contents; a folder not yet seen takes `initially`. */
	public function folderState(dir:String, initially = false):Signal<Bool> {
		var open = folderOpen.get(dir);
		if (open == null) {
			open = Signal.make(initially);
			folderOpen.set(dir, open);
			folderStates.set(folderStates.get() + 1);
		}
		return open;
	}

	/** The row of the Explorer that stands for the file in front: the file, or the top-most closed folder above it. */
	function selectionRow():String {
		var file = active.get(), root = props.display.cwd;
		if (file == SETTINGS)
			return settingsCategory.get() == "build" && props.display.hxml != null ? props.display.hxml : file;
		if (file == "" || !file.startsWith(root))
			return file;
		var chain = [], dir = haxe.io.Path.directory(file);
		while (dir.length > root.length && dir.startsWith(root)) {
			chain.unshift(dir);
			dir = haxe.io.Path.directory(dir);
		}
		for (d in chain) {
			var open = folderOpen.get(d);
			if (open != null && !open.get())
				return d;
		}
		return file;
	}

	/** Puts the tree's selection back on the file in front, or on the closed folder above it, after a click took it elsewhere. */
	function keepSelection():Void {
		var row = selectionRow();
		if (treeSelected.get() != row)
			treeSelected.set(row);
	}

	/** The project's source folders as the build names them: the label as written, and the folder in full. */
	function classpaths():Array<{label:String, dir:String}> {
		if (themeStudio != null)
			return [{label: haxe.io.Path.withoutDirectory(props.display.cwd), dir: props.display.cwd}];
		if (extension != null)
			return extension.sourceDirs();
		var args = props.display.args, out = [], base = props.display.cwd;
		for (i in 0...args.length - 1)
			if (args[i] == "--cwd") base = haxe.io.Path.isAbsolute(args[i + 1]) ? args[i + 1] : haxe.io.Path.join([base, args[i + 1]]);
			else if (args[i] == "-cp" || args[i] == "-p" || args[i] == "--class-path") {
				var dir = haxe.io.Path.isAbsolute(args[i + 1]) ? args[i + 1] : haxe.io.Path.join([base, args[i + 1]]);
				if (sys.FileSystem.exists(dir) && sys.FileSystem.isDirectory(dir))
					out.push({label: args[i + 1], dir: dir});
			}
		return out;
	}

	/** The build file in the tree, which opens the form and not the text; for an extension, its config file, which opens its form. */
	function buildRow():Element {
		if (themeStudio != null)
			return tagged(<tree-item value={themeStudio.file} label={haxe.io.Path.withoutDirectory(themeStudio.file)} icon={Icons.PALETTE_LINE}/>, themeStudio.file);
		if (extension != null)
			return tagged(<tree-item value={extension.file} label={haxe.io.Path.withoutDirectory(extension.file)} icon={Icons.SETTINGS_3_LINE}/>, extension.file);
		var entry = projectEntry();
		if (entry == null)
			return <div/>;
		return tagged(<tree-item value={entry} label={haxe.io.Path.withoutDirectory(entry)} icon={Icons.SETTINGS_3_LINE}/>, entry);
	}

	function projectEntry():Null<String> return props.display.project == null ? props.display.hxml : props.display.project.file;

	function folders():Array<Element> {
		var entries = folderEntries(props.display.cwd);
		for (cp in classpaths())
			if (!FileOps.inside(props.display.cwd, cp.dir)) entries.push(folder(cp.dir, cp.label, true));
		return entries;
	}

	/** The project's files with the open ones first, in the order of their tabs. */
	function recentFiles():Array<String> {
		var all = projectFiles(), tabs = open.get(), indexed = new Map<String, Bool>(), opened = new Map<String, Bool>();
		for (file in all) indexed.set(file, true);
		for (file in tabs) opened.set(file, true);
		return [for (file in tabs) if (indexed.exists(file)) file].concat([for (file in all) if (!opened.exists(file)) file]);
	}

	function refreshFileIndex():Void {
		fileIndex.refresh([for (cp in classpaths()) cp.dir]);
		if (fileIndexScheduled || gone) return;
		fileIndexScheduled = true;
		ashui.animation.AnimationScheduler.main.after(.016, pollFileIndex);
	}

	function pollFileIndex():Void {
		fileIndexScheduled = false;
		if (gone) return;
		if (fileIndex.poll()) fileIndexRevision.set(fileIndexRevision.get() + 1);
		if (fileIndex.busy()) {
			fileIndexScheduled = true;
			ashui.animation.AnimationScheduler.main.after(.016, pollFileIndex);
		}
	}

	/** Openable files from the most recent worker snapshot. */
	function projectFiles():Array<String> {
		fileIndexRevision.get();
		return [for (path in fileIndex.paths) if (isSource(path)) path];
	}

	/** The tree items for what is in `dir`: its folders and openable files. */
	function folderEntries(dir:String):Array<Element> {
		var names = sys.FileSystem.readDirectory(dir);
		names.sort(Reflect.compare);
		var children:Array<Element> = [], sources = classpaths();
		for (name in names) {
			var path = haxe.io.Path.join([dir, name]);
			if (path == projectEntry()) continue;
			if (name.startsWith("."))
				continue;
			if (sys.FileSystem.isDirectory(path))
				children.push(folder(path, name, Lambda.exists(sources, cp -> FileOps.inside(path, cp.dir))));
			else if (isSource(path))
				children.push(tagged(<tree-item value={path} label={name} icon={fileIcon(path)}/>, path));
		}
		return children;
	}

	function folder(dir:String, label:String, expanded:Bool):Element {
		return tagged(<tree-item value={dir} label={label} icon={Icons.FOLDER_LINE} expanded={folderState(dir, expanded)} load={() -> folderEntries(dir)}/>, dir);
	}

	/** The open files' tabs, the path to the file in front, and its editor; with nothing open, the welcome page alone. */
	function editorCard():Element
		return <div id="rayde-editor-card" class="rayde-card flex flex-col flex-1 min-h-0">
			<for {has in [open.get().length > 0]}>${tabStrip(has)}</for>
			<for {has in [open.get().length > 0]}>${has ? editors() : welcome()}</for>
		</div>;

	function tabLabel(file:String):String
		return file.startsWith(HISTORY_TAB) && historyTabs.exists(file) ? "Local: " + haxe.io.Path.withoutDirectory(historyTabs.get(file).file) + " #" + historyTabs.get(file).revision : file == THEME_TAB ? (themeStudio == null ? "Theme" : themeStudio.theme.get().name) : isTab(file) ? tabTitle(file) : file == SETTINGS ? "Settings" : isViewTab(file) ? viewTabTitle(file) : haxe.io.Path.withoutDirectory(file);

	function viewTabTitle(file:String):String {
		var v = viewOfTab(file);
		return v == null ? "Extension" : v.title;
	}

	function tabIcon(file:String):ashui.svg.SvgDocument {
		if (file.startsWith(HISTORY_TAB)) return Icons.HISTORY_LINE;
		if (isTab(file)) {
			var studio = studios.get(tabStudio(file));
			return studio != null && studio.manifest != null ? ViewIcons.of(studio.manifest) : Icons.PUZZLE_LINE;
		}
		return file == THEME_TAB ? Icons.PALETTE_LINE : file == SETTINGS ? Icons.SETTINGS_3_LINE : isViewTab(file) && viewOfTab(file) != null ? ViewIcons.ofView(containerOfTab(file).extension, viewOfTab(file)) : fileIcon(file);
	}

	/** The icon a file has in the Explorer and on its tab. */
	function fileIcon(file:String):ashui.svg.SvgDocument
		return StringTools.endsWith(file, ".hx") ? Icons.HAXE : isExtension(file) ? Icons.PUZZLE_LINE : Manifest.isManifest(file) ? Icons.SETTINGS_3_LINE : isMarkdown(file) ? Icons.MARKDOWN_LINE : ImagePreview.supports(file) ? Icons.IMAGE_LINE : Icons.BRACES_LINE;

	function tabStrip(has:Bool):Element {
		if (!has)
			return <div/>;
		return <file-tabs files={open} active={active} dirty={dirty} onClose={closeFile} label={tabLabel} icon={tabIcon} trailing={editorMenu()}/>;
	}

	function editors():Element {
		return <div class="flex flex-col flex-1 min-h-0">
			<for {file in [active.get() == SETTINGS ? SETTINGS + ":" + settingsCategory.get() : active.get()]}>${breadcrumb(active.get())}</for>
			<tabs id="rayde-tabs" value={active} class="flex-1 min-h-0">
				<tabs-list indicator={false} class="rayde-nolist"/>
				<for {file in open}>${retainedPage(file)}</for>
			</tabs>
		</div>;
	}

	/** A keyed page keeps its tab shell and extension controls; code views mount only while active. */
	function retainedPage(file:String):Element {
		var content:TabsContent = cast page(file);
		content.tabs.set(active);
		return content;
	}

	function welcome():Element
		return <welcome name={props.name} runtime={runtime()} root={props.display.cwd}
			build={projectEntry() == null ? "build.hxml" : haxe.io.Path.withoutDirectory(projectEntry())} haxe={compilerVersion()} canRun={props.display.project == null || props.display.project.runnable}
			sources={[for (cp in classpaths()) cp.label]} files={() -> projectFiles().length} main={mainFile()} recent={recent} problems={problems}
			onOpen={path -> openFile(path)} onFiles={() -> openCenter()} onCommands={() -> openCenter(">")} onRun={run} onBuild={openBuild}/>;

	/** Where `file` sits in the project, folder by folder. */
	function breadcrumb(file:String):Element {
		if (file.startsWith(HISTORY_TAB) && historyTabs.exists(file)) return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs([haxe.io.Path.withoutDirectory(historyTabs.get(file).file), "Local history"])}</breadcrumb>;
		if (file == SETTINGS)
			return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs(["Settings", SettingsPage.labelOf(SettingsPage.category(settingsCategory.get()), extension)])}</breadcrumb>;
		if (file == THEME_TAB)
			return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs([themeStudio == null ? "Theme" : themeStudio.theme.get().name, "Theme Studio"])}</breadcrumb>;
		if (isViewTab(file))
			return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs([viewTabTitle(file)])}</breadcrumb>;
		if (isTab(file))
			return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs([extension == null ? "Extension" : extension.name, tabTitle(file)])}</breadcrumb>;
		var root = haxe.io.Path.addTrailingSlash(props.display.cwd);
		var parts = (file.startsWith(root) ? file.substr(root.length) : file).split("/");
		return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs(parts)}</breadcrumb>;
	}

	function crumbs(parts:Array<String>):Array<Element>
		return [for (i => part in parts) <breadcrumb-item current={i == parts.length - 1}>${part}</breadcrumb-item>];

	function editorRef(file:String):Ref<CodeEditor> {
		var ref = editorRefs.get(file);
		if (ref == null) {
			ref = new Ref<CodeEditor>();
			editorRefs.set(file, ref);
		}
		return ref;
	}

	/** One open file's editor, which checks the file as it is typed. */
	function page(file:String):Element {
		if (file.startsWith(HISTORY_TAB)) return <tabs-content value={file} class="flex-1 min-h-0"><if {active.get() == file}>${historyPage(file)}</if></tabs-content>;
		if (file == THEME_TAB && themeStudio != null)
			return <tabs-content value={file} class="flex-1 min-h-0">
				<theme-studio-view studio={themeStudio} appearance={appearance} revision={settingsRevision} onScheme={pickScheme} onText={openThemeText} onOpen={name -> openFile(haxe.io.Path.join([props.display.cwd, name]))}/>
			</tabs-content>;
		if (isTab(file)) {
			var owner = studios.get(tabStudio(file));
			return <tabs-content value={file} class="flex-1 min-h-0">
				<if {active.get() == file}>{owner == null ? <div/> : <studio-tab studio={owner} root={tabRoot(file)}/>}</if>
			</tabs-content>;
		}
		if (isViewTab(file)) {
			var c = containerOfTab(file);
			if (c == null) return <tabs-content value={file} class="flex-1 min-h-0"><div/></tabs-content>;
			var studio = studios.get(c.extension.mainPath());
			return <tabs-content value={file} class="flex-1 min-h-0">
				<studio-view studio={studio} framed={true} view={viewOfTab(file)} onMocks={() -> openMocks(studio)} onConsole={() -> showPanel("extension")}/>
			</tabs-content>;
		}
		if (file == SETTINGS)
			return <tabs-content value={file} class="flex-1 min-h-0">
				<settings-page category={settingsCategory} root={props.display.cwd} build={buildModel} terminal={terminalSettings} appearance={appearance} bindings={bindings}
					commands={commandList} libraries={libraries} onBuildChanged={buildChanged} onTerminalChanged={() -> settingsRevision.set(settingsRevision.get() + 1)}
					onAppearanceChanged={() -> {
						windowStyle.set(WindowControls.styleFor(appearance.windowControls));
						settingsRevision.set(settingsRevision.get() + 1);
					}} onBindingsChanged={bindingsChanged} bindingChanges={bindingsRevision}
					extension={extension} onExtensionChanged={extensionChanged} onEditExtensionText={() -> openFile(extension.file)}
					manager={extensionManager} extensionChanges={extensionRevision} onExtensionToggle={toggleExtension}
					listening={() -> extension == null ? [] : extensionStudio().listening()}/>
			</tabs-content>;
		return pageOfFile(file);
	}

	/** The grammar the editor highlights `file` by. */
	static function languageOf(file:String):String
		return StringTools.endsWith(file, ".hx") || StringTools.endsWith(file, ".rays") ? "haxe" : StringTools.endsWith(file, ".json") || StringTools.endsWith(file, ".rayext") || StringTools.endsWith(file, ".raytheme") ? "json" : "plain";

	function pageOfFile(file:String):Element {
		if (ImagePreview.supports(file)) return <tabs-content value={file} class="flex-1 min-h-0"><if {active.get() == file}>${imagePage(file)}</if></tabs-content>;
		if (isExtension(file) && extension == null)
			return studioPage(file);
		return <tabs-content value={file} class="flex-1 min-h-0">${activeCodeEditor(file)}</tabs-content>;
	}

	function activeCodeEditor(file:String):Element
		return <if {active.get() == file}>${codeEditor(file)}</if>;

	function imageTextMode(file:String):Signal<Bool> {
		if (!imageTextModes.exists(file)) imageTextModes.set(file, Signal.make(false));
		return imageTextModes.get(file);
	}

	function imagePage(file:String):Element {
		if (!imageViews.exists(file)) imageViews.set(file, ImagePreview.state());
		var mode = imageTextMode(file);
		return <for {code in [mode.get()]}>
			<if {code && ImagePreview.isSvg(file)}>
				<div class="flex flex-col flex-1 min-h-0">
					<div class="rayde-image-tools flex items-center justify-between px-3 py-2 shrink-0"><text class="text-xs text-text-secondary">SVG source</text>
						<tooltip label="Open Preview" side="bottom"><button id="rayde-image-show-preview" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> mode.set(false)}><icon document={Icons.IMAGE_LINE} class="size-4"/></button></tooltip>
					</div>
					${codeEditor(file)}
				</div>
			<else>
				<image-preview file={file} state={imageViews.get(file)} source={ImagePreview.isSvg(file) ? buffer(file) : null} onEdit={ImagePreview.isSvg(file) ? () -> mode.set(true) : null}/>
			</if>
		</for>;
	}

	function codeEditor(file:String):Element {
		if (restoredTabs.remove(file)) check(file);
		if (languageOf(file) == "plain" && !nativeSyntax.exists(file)) nativeSyntax.set(file, TextMateSyntax.forFile(file));
		var editor = <code-editor ref={editorRef(file)} id={"rayde-editor-" + haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(file))} state={documentState(file)} language={languageOf(file)} highlighter={nativeSyntax.get(file)} findShortcuts={false}
			lineNumbers={true} folding={true} indentGuides={true} highlightBrackets={true} minimap={true} gutterMarkers={true} onNavigate={offset -> definitionAt(file, offset)} hover={offset -> hintAt(file, offset)} tabSize={4} insertSpaces={false} onInput={_ -> {
				edited(file);
				assistInput(file);
			}}
			class="flex-1 min-h-0"/>;
		holdCaretWhileScrolling(editorRef(file).get());
		annotate(file, editorRef(file).get());
		assistWatch(file, editorRef(file).get());
		var mounted = editorRef(file).get();
		Owner.onCleanup(() -> assist.stop(file, mounted));
		return editor;
	}

	/** The text offset of a position, its line and character counted from zero; the end of the line, or of the text, where there is none. */
	static function offsetOf(text:String, line:Int, character:Int):Int {
		var at = 0;
		for (_ in 0...line) {
			var next = text.indexOf("\n", at);
			if (next < 0)
				return text.length;
			at = next + 1;
		}
		var end = text.indexOf("\n", at);
		return Std.int(Math.min(at + character, end < 0 ? text.length : end));
	}

	/** The debugger of the extension `file` is part of, if it is a RayScript file of one. */
	function debuggerOf(file:String):Null<Debugger> {
		if (!isExtension(file))
			return null;
		var studio = extension != null ? extensionStudio() : studios.get(file);
		return studio == null ? null : studio.debug;
	}

	/**
	 * What the editor shows beside and in the text: the breakpoints in the gutter, which a click puts on a line or takes
	 * off and which move with the text; the line an extension is stopped on; and the compiler's problems underlined.
	 */
	function annotate(file:String, editor:Null<CodeEditor>):Void {
		if (editor == null)
			return;
		var d = debuggerOf(file);
		if (d != null) {
			editor.onGutterClick = (line, e) -> if (e.button == null || e.button.match(Left)) d.toggle(file, line + 1);
			new ashui.reactive.Watch(() -> d.breakpoints.get(), list -> editor.markers("breakpoints", [for (b in list) if (b.file == file) {line: b.line - 1, className: "ui-code-marker-breakpoint", title: "Breakpoint"}], true));
			new ashui.reactive.Watch(() -> {
				d.stopped.get();
				d.frame.get();
				0;
			}, _ -> markStop(file, editor, d), (_, _) -> false);
		}
		new ashui.reactive.Watch(() -> problems.get(), list -> {
			var text = buffer(file).get();
			editor.decorate("problems", [for (p in list) if (p.file == file) squiggle(text, p)]);
		});
	}

	/** Documentation for a diagnostic at the pointer, or the language server's type and documentation. */
	function hintAt(file:String, offset:Int):Null<ashui.components.code.CodeHints.CodeHint> {
		var editor = editorOf(file);
		var marked = editor == null ? [] : editor.decorationsAt(offset);
		if (marked.length > 0) {
			var titled = [for (d in marked) if (d.title != null && d.title != "") d];
			if (titled.length == 0) return null;
			var from = titled[0].from, to = titled[0].to;
			for (d in titled) {
				from = Std.int(Math.min(from, d.from));
				to = Std.int(Math.max(to, d.to));
			}
			var message = [for (d in titled) d.title].join("\n\n");
			return {from:from, to:Std.int(Math.max(to, from + 1)),
				className:StringTools.replace(titled[0].className, "squiggle", "hint"),
				renderDocs:() -> HoverDocumentation.render({kind:"markdown", value:message})};
		}
		if (!StringTools.endsWith(file, ".hx") && languageServers.client(file) == null)
			return null;
		var text = buffer(file).get();
		var client = languageServers.client(file);
		if (client != null) {
			if (editor == null || !client.supports("hoverProvider")) return null;
			languageServers.sync(file, text);
			client.request("textDocument/hover", LspProtocol.at(file, text, offset), result -> {
				if (gone || editorOf(file) != editor || editor.value.get() != text || editor.hoverOffset != offset || result == null) return;
				var range:Dynamic = result.range;
				editor.showHint({from:range == null ? offset : LspProtocol.offset(text, range.start),
					to:range == null ? offset + 1 : LspProtocol.offset(text, range.end), renderDocs:() -> HoverDocumentation.render(result.contents)});
			}, file + "#hover");
			return null;
		}
		var found = try props.display.hover(file, Display.byteOffset(text, offset), text) catch (_:Dynamic) null;
		if (found == null || found.range == null)
			return null;
		return {
			from: offsetOf(text, found.range.start.line, found.range.start.character),
			to: offsetOf(text, found.range.end.line, found.range.end.character),
			signature: found.type,
			language: "haxe",
			docs: found.documentation
		};
	}

	/** Marks the line of the frame chosen in the stack when it is in `file`, and nothing otherwise. */
	function markStop(file:String, editor:CodeEditor, d:Debugger):Void {
		var stop = d.stopped.get(), frame = stop == null ? null : stop.frames[d.frame.get()];
		if (frame == null || frame.file != file) {
			editor.decorate("stopped", []);
			return;
		}
		var at = offsetOf(buffer(file).get(), frame.line - 1, 0);
		editor.decorate("stopped", [{from: at, to: at, className: "ui-code-line-current", wholeLine: true}], true);
	}

	function squiggle(text:String, p:Diagnostic):ashui.components.code.CodeAnnotations.CodeDecoration {
		var from = offsetOf(text, p.range.start.line, p.range.start.character), to = offsetOf(text, p.range.end.line, p.range.end.character);
		if (to <= from)
			to = Std.int(Math.min(text.length, from + 1));
		var kind = p.severity == 1 ? "ui-code-squiggle-error" : p.severity == 2 ? "ui-code-squiggle-warning" : "ui-code-squiggle-info";
		return {from: from, to: to, className: kind, title: p.message};
	}

	/** How long the caret stays steady after the last scroll step before it blinks again, in seconds. */
	static inline var CARET_REST = .6;

	/**
	 * Keeps the caret steady while the editor scrolls, and blinking again once it has rested: a blink fades over
	 * several frames, each a full draw, and those compete with the frames of a scroll.
	 */
	function holdCaretWhileScrolling(editor:Null<CodeEditor>):Void {
		if (editor == null || editor.scroll == null)
			return;
		var last = 0., holding = false, check:Void->Void = null;
		var timer:Null<ashui.animation.AnimationScheduler.Timer> = null;
		Owner.onCleanup(() -> {
			if (timer != null) timer.cancel();
			editor = null;
		});
		check = () -> {
			if (editor == null) return;
			var left = CARET_REST - (haxe.Timer.stamp() - last);
			if (left > 0)
				timer = ashui.animation.AnimationScheduler.main.after(left, check);
			else {
				holding = false;
				if (editor.editing.showsCaret())
					editor.editing.restartBlink();
			}
		};
		new ashui.reactive.Watch(() -> editor.scroll.y.get(), _ -> {
			last = haxe.Timer.stamp();
			if (holding)
				return;
			holding = true;
			editor.editing.stopBlink();
			timer = ashui.animation.AnimationScheduler.main.after(CARET_REST, check);
		});
	}

	/** An extension: its code, and beside it the Preview of what it draws. */
	function studioPage(file:String):Element {
		var studio = studioOf(file);
		return <tabs-content value={file} class="flex-1 min-h-0">
			<resizable id="rayde-studio-columns" class="flex-1 min-h-0">
				<resizable-panel minSize={200}>${activeCodeEditor(file)}</resizable-panel>
				<resizable-panel size={previewWidth} minSize={220}><studio-view studio={studio} onMocks={() -> openMocks(studio)} onConsole={() -> showPanel("extension")}/></resizable-panel>
			</resizable>
		</tabs-content>;
	}

	/** Opens the file that answers the extension's remote calls while it is developed, making it when there is none. */
	function openMocks(studio:Studio):Void {
		var path = studio.mocksPath();
		if (!sys.FileSystem.exists(path))
			sys.io.File.saveContent(path, "{\n}\n");
		openFile(path);
	}

	/** Problems and the Output of a run, as VS Code's panel names them. */
	/** What a view the extension put in the bottom panel shows, under its tab. */
	function panelContent(c:Container):Element
		return <tabs-content value={"ext-" + c.id} class="flex-1 min-h-0 pt-1">${extensionBody(c, "")}</tabs-content>;

	function bottomCard():Element
		return <div id="rayde-panel" class="rayde-card panel relative flex flex-col flex-1 min-h-0">
			<tabs id="rayde-bottom" value={bottom} size={Sm} class="flex-1 min-h-0 px-2 pt-2">
				<tabs-list class="shrink-0">
					<tabs-trigger id="rayde-tab-problems" value="problems">Problems</tabs-trigger>
					<tabs-trigger id="rayde-tab-console" value="console">Output</tabs-trigger>
					<tabs-trigger id="rayde-tab-terminal" value="terminal">Terminal</tabs-trigger>
					<tabs-trigger id="rayde-tab-extension" value="extension">Extension</tabs-trigger>
					{[for (c in containers) if (c.location == "panel") <tabs-trigger id={"rayde-tab-" + c.id} value={"ext-" + c.id}>${c.title}</tabs-trigger>]}
				</tabs-list>
				<tabs-content value="problems" class="flex-1 min-h-0 pt-1"><if {panelShown.get() && bottom.get() == "problems"}><for {list in [problems.get()]}>${problemsPane(list)}</for></if></tabs-content>
				<tabs-content value="console" class="flex-1 min-h-0 pt-1">
					<if {panelShown.get() && bottom.get() == "console"}>${outputPane()}</if>
				</tabs-content>
				<tabs-content value="terminal" class="flex-1 min-h-0 pt-1"><for {g in [terminalGeneration.get()]}>${terminalPane()}</for></tabs-content>
				<tabs-content value="extension" class="flex-1 min-h-0 pt-1"><studio-panels studio={activeStudio} onOpen={goTo}/></tabs-content>
				{[for (c in containers) if (c.location == "panel") panelContent(c)]}
			</tabs>
			<div class="flex items-center gap-1" position={Absolute} right={8} top={6}>
				<for {tab in [bottom.get()]}>${panelTools(tab)}</for>
				<tooltip label="Close panel" side="top"><button id="rayde-panel-close" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> closePanel()}><icon document={Icons.CLOSE_LINE} class="size-4"/></button></tooltip>
			</div>
		</div>;

	function outputPane():Element {
		var items:Array<Element> = [<select-item value="build">Build</select-item>];
		for (e in extensionManager.extensions) items.push(<select-item value={"ext:" + e.installed.id}>${e.installed.name}</select-item>);
		return <div class="flex flex-col flex-1 min-h-0 gap-2">
			<select id="rayde-output-channel" value={outputChannel.get()} size={Sm} class="rayde-control-wide" onChange={value -> { outputChannel.set(value); refreshExtensionOutput(); }}>{items}</select>
			<for {channel in [outputChannel.get()]}>
				{channel == "build" ? buildLog() : extensionLog()}
			</for>
		</div>;
	}

	function buildLog():Element {
		buildOutputSyntax.spans = outputSpans.get("build");
		var view:CodeView = <code-view id="rayde-console" state={outputState("build")} highlighter={buildOutputSyntax} tokenStyles={true} lineNumbers={false} folding={false} class="rayde-output flex-1 min-h-0"/>;
		new ashui.reactive.Watch(() -> outputStyleRevision.get(), _ -> {
			var spans = outputSpans.get("build");
			if (buildOutputSyntax.spans == spans) return;
			buildOutputSyntax.spans = spans;
			view.metrics.syntax = new OutputHighlighter(null, spans);
			view.expandAll();
		});
		return view;
	}

	function extensionLog():Element {
		var channel = outputChannel.get(), kinds = extensionOutputKinds.get(), spans = outputSpans.get(channel);
		var syntax = outputSyntax.get(channel);
		if (syntax == null) { syntax = new OutputHighlighter(kinds, spans); outputSyntax.set(channel, syntax); }
		var view:CodeView = <code-view ref={extensionOutputView} id="rayde-extension-output" state={outputState(channel)} highlighter={syntax} tokenStyles={true} lineNumbers={false} folding={false} class="rayde-output flex-1 min-h-0"/>;
		new ashui.reactive.Watch(() -> { outputStyleRevision.get(); extensionOutputKinds.get(); }, _ -> {
			var kinds = extensionOutputKinds.get(), spans = outputSpans.get(channel);
			if (syntax.kinds == kinds && syntax.spans == spans) return;
			syntax.kinds = kinds; syntax.spans = spans;
			view.metrics.syntax = new OutputHighlighter(kinds, spans);
			view.expandAll();
		});
		return view;
	}

	/** The screen of the terminal in front, split with its neighbours when it is, and the list of terminals beside it when there are several; or an offer of one while none is running. */
	function terminalPane():Element {
		var session = current();
		if (session == null)
			return <div id="rayde-terminal-empty" class="flex flex-col flex-1 items-center justify-center gap-3">
				<text class="text-sm text-text-tertiary">No terminal is running.</text>
				<button id="rayde-terminal-new" variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> newTerminal()}>New terminal</button>
			</div>;
		var members = groupOf(session.id);
		// A view that takes a terminal over from another shows all of its rows.
		for (m in members)
			m.terminal.invalidate();
		return <div class="flex flex-1 min-h-0 min-w-0">
			${screens(members)}
			<if {sessions.length > 1}><for {id in [terminalActive.get()]}>${terminalList()}</for></if>
		</div>;
	}

	/** One screen, or several side by side with a divider to drag between each two. */
	function screens(members:Array<Session>):Element {
		if (members.length == 1)
			return screen(members[0]);
		return <resizable id="rayde-terminal-split" class="flex-1 min-h-0 min-w-0">{splitPanels(members)}</resizable>;
	}

	function splitPanels(members:Array<Session>):Array<Element>
		return [for (m in members) <resizable-panel minSize={140}>${screen(m)}</resizable-panel>];

	function screen(s:Session):Element {
		var ref = views.get(s.id);
		if (ref == null) {
			ref = new Ref<TerminalView>();
			views.set(s.id, ref);
		}
		var id = s.id;
		return <terminal-view ref={ref} terminal={s.terminal} shown={() -> panelShown.get() && bottom.get() == "terminal"} settings={terminalSettings} changes={settingsRevision}
			onExit={code -> say(s.terminal.failedToStart() ? "Could not start " + s.profile.name : s.profile.name + " exited with code " + code)} onFocus={() -> noteFocus(id)} reserved={reservedKey}/>;
	}

	/** The terminals running down the right of the pane, a screen's terminals together; the one in front lit. */
	function terminalList():Element
		return <div id="rayde-terminal-list" class="rayde-term-list flex flex-col shrink-0 gap-1 p-1" width={170}>{terminalRows()}</div>;

	function terminalRows():Array<Element> {
		var out = [], seen = new Map<Int, Bool>();
		for (s in sessions) {
			out.push(terminalRow(s, seen.exists(s.group)));
			seen.set(s.group, true);
		}
		return out;
	}

	function terminalRow(s:Session, split:Bool):Element {
		var id = s.id, row = <div id={"rayde-terminal-item-" + id} class="rayde-term-item flex items-center gap-2 px-2 shrink-0 cursor-pointer" height={28} onClick={_ -> selectTerminal(id)}>
			<icon document={split ? Icons.LAYOUT_COLUMN_LINE : Icons.TERMINAL_BOX_LINE} class="size-4 shrink-0"/>
			<text class="text-xs flex-1 min-w-0">${s.profile.name}</text>
			<tooltip label="Kill terminal" side="left"><button variant={Ghost} size={Icon} class="rayde-remove rayde-term-kill" onClick={e -> {
				e.stopPropagation();
				endSession(id);
			}}><icon document={Icons.CLOSE_LINE} class="size-3.5"/></button></tooltip>
		</div>;
		var identity = ashui.css.Identity.of(row.tree, row.node.id);
		if (s.id == activeSession)
			identity.setAttribute("data-on", "");
		if (split)
			identity.setAttribute("data-split", "");
		return row;
	}

	/** What the panel's tab row holds for the tab in view, before its close button: for the terminal, + and the menu beside it, and a bin. */
	function panelTools(tab:String):Element {
		if (tab != "terminal")
			return <div/>;
		var mod = Sys.systemName() == "Mac" ? "⌘" : "Ctrl+";
		return <div class="flex items-center gap-1">
			<div class="flex items-center">
				<tooltip label="New terminal" side="top"><button id="rayde-terminal-add" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> newTerminal()}><icon document={Icons.ADD_LINE} class="size-4"/></button></tooltip>
				<dropdown-menu ref={profilesMenu} id="rayde-terminal-profiles">
					<dropdown-menu-trigger id="rayde-terminal-profiles-trigger" variant={Ghost} size={Icon} class="rayde-panel-button rayde-split"></dropdown-menu-trigger>
					<dropdown-menu-content>
						<if {profilesMenu.get() != null && profilesMenu.get().opened.get()}>
						<dropdown-menu-item id="rayde-menu-new-terminal" shortcut="Ctrl+Shift+`" onSelect={() -> newTerminal()}>New Terminal</dropdown-menu-item>
						<dropdown-menu-item id="rayde-menu-split-terminal" shortcut={mod + "\\"} onSelect={() -> splitTerminal()}>Split Terminal</dropdown-menu-item>
						<dropdown-menu-separator/>
						<dropdown-menu-label>Profiles</dropdown-menu-label>
						{profileItems()}
						<dropdown-menu-separator/>
						<dropdown-menu-item id="rayde-menu-split-profile" onSelect={splitWithProfile}>Split Terminal with Profile…</dropdown-menu-item>
						<dropdown-menu-item id="rayde-menu-default-profile" onSelect={selectDefaultProfile}>Select Default Profile…</dropdown-menu-item>
						<dropdown-menu-item id="rayde-menu-terminal-settings" onSelect={openTerminalSettings}>Configure Terminal Settings</dropdown-menu-item>
						<dropdown-menu-separator/>
						<dropdown-menu-item id="rayde-menu-run-task" onSelect={runTaskPicker}>Run Task…</dropdown-menu-item>
						<dropdown-menu-item id="rayde-menu-configure-tasks" onSelect={configureTasks}>Configure Tasks…</dropdown-menu-item>
						</if>
					</dropdown-menu-content>
				</dropdown-menu>
			</div>
			<tooltip label="Kill terminal" side="top"><button id="rayde-terminal-kill" variant={Ghost} size={Icon} class="rayde-panel-button rayde-remove" onClick={_ -> killTerminal()}><icon document={Icons.DELETE_BIN_LINE} class="size-4"/></button></tooltip>
		</div>;
	}

	/** One item for each shell the machine has, with where it is, the default marked. */
	function profileItems():Array<Element> {
		var selected = defaultProfile().name;
		return [for (p in Profiles.list()) profileItem(p, selected)];
	}

	function profileItem(p:Profile, selected:String):Element
		return <dropdown-menu-item id={"rayde-profile-" + p.name} shortcut={p.program} onSelect={() -> newTerminal(p)}>${p.name == selected ? p.name + " (default)" : p.name}</dropdown-menu-item>;

	function problemsPane(list:Array<Diagnostic>):Element {
		var pane = <div id="rayde-problems" class="flex flex-col flex-1 min-h-0 overflow-auto">
			<if {list.length == 0}><div class="px-2 py-1"><text class="text-xs text-text-tertiary">No problems in the open files.</text></div></if>
		</div>;
		var scroll = ashui.input.Scroll.attach(pane.node, false, true);
		if (list.length == problemScrollCount) scroll.y.set(problemScrollY);
		var capacity = Signal.make(24);
		var layout = (current:ashui.layout.LayoutTree) -> {
			if (current != pane.tree) return false;
			var bounds = current.getBounds(pane.node);
			var next = bounds == null ? 24 : Std.int(Math.max(24, Math.ceil(bounds.height / 28) + 6));
			if (capacity.get() == next) return false;
			capacity.set(next); return true;
		};
		ashui.layout.LayoutTree.layoutHooks.push(layout);
		Owner.onCleanup(() -> ashui.layout.LayoutTree.layoutHooks.remove(layout));
		var first = Computed.make(() -> Std.int(Math.max(0, Math.min(list.length - 1, Math.floor(scroll.y.get() / 28)) - 3)));
		var end = Computed.make(() -> Std.int(Math.min(list.length, first.get() + capacity.get())));
		var visible = Computed.make(() -> list.slice(first.get(), end.get()));
		pane.appendChild(<div height={Computed.make(() -> first.get() * 28.)} flexShrink={0}/>);
		pane.appendChild(<for {problem in visible}>${problemRow(problem)}</for>);
		pane.appendChild(<div height={Computed.make(() -> (list.length - end.get()) * 28.)} flexShrink={0}/>);
		Owner.onCleanup(() -> { problemScrollY = scroll.y.get(); problemScrollCount = list.length; });
		return pane;
	}

	function problemRow(p:Diagnostic):Element {
		var located = p.file != null && p.range != null;
		var location = located ? haxe.io.Path.withoutDirectory(p.file) + " [" + (p.range.start.line + 1) + ", " + (p.range.start.character + 1) + "]" : "Workspace";
		var row = <div class="rayde-problem flex items-center gap-2 px-2 py-1 shrink-0" height={28} onClick={_ -> { if (located) goTo(p.file, p.range.start.line, p.range.start.character); }}>
			<if {p.severity == 1}><icon document={Icons.CLOSE_CIRCLE_LINE} class="size-4 text-error"/>
			<else><icon document={Icons.ALERT_LINE} class="size-4 text-warning"/></if>
			<text class="text-xs flex-1 min-w-0">${p.message.split("\n")[0]}</text>
			<text class="text-xs text-text-tertiary">${location}</text>
		</div>;
		if (located) ashui.css.Identity.of(row.tree, row.node.id).addClasses(["cursor-pointer"]);
		return row;
	}

	/** The runtime the project runs on, the problem counts, and where the run stands. */
	function statusBar():Element
		return <div id="rayde-status-bar" class="rayde-status flex items-center gap-2 px-3 shrink-0" height={28}>
			<tooltip label={"This project runs on the " + runtime() + " runtime"} side="top">
				<div id="rayde-runtime" class="rayde-status-item flex"><icon document={Icons.TERMINAL_BOX_LINE} class="size-3.5"/><text>${runtime() + " runtime"}</text></div>
			</tooltip>
			<for {list in [problems.get()]}>${problemCounts(list)}</for>
			<div class="flex-1"/>
			<if {notice.get() != ""}><text id="rayde-notice">${notice}</text></if>
			<for {state in [runState.get()]}>${runStatus(state)}</for>
			<for {on in [panelShown.get()]}>${panelItem(on)}</for>
			<for {server in [languageStatus()]}><if {server != null}>${languageServerItem(server)}</if></for>
			<div class="rayde-status-item flex"><text>Haxe</text></div>
		</div>;

	function languageStatus():Null<{id:String, owner:String, name:String, state:String, indexing:Bool}> {
		languageStatusRevision.get(); languageRevision.get();
		return languageServers.status(active.get());
	}

	function languageServerItem(server:{id:String, owner:String, name:String, state:String, indexing:Bool}):Element {
		var extension = Lambda.find(extensionManager.extensions, entry -> entry.connection.file == server.owner);
		var icon = extension == null || extension.connection.manifest == null ? Icons.CODE_S_SLASH_LINE : ViewIcons.of(extension.connection.manifest);
		var running = ["ready", "starting", "restarting"].indexOf(server.state) >= 0;
		if (!running) icon = ViewIcons.inactive(icon);
		var indexing = Computed.make(() -> {
			languageActivityRevision.get();
			var current = languageServers.status(active.get());
			return current != null && current.id == server.id && current.indexing;
		});
		var status = Computed.make(() -> indexing.get() ? "indexing " + haxe.io.Path.withoutDirectory(active.get()) : server.state == "idle" ? "not started" : server.state);
		var description = Computed.make(() -> server.name + " — " + status.get());
		var label = server.name + (server.state == "ready" ? "" : " · " + (server.state == "idle" ? "not started" : server.state));
		var picture:Element = <icon document={icon} class="size-3.5 rayde-lsp-icon"/>;
		ashui.css.Identity.of(picture.tree, picture.node.id).bindBooleanAttribute("data-indexing", indexing);
		if (!running) ashui.css.Identity.of(picture.tree, picture.node.id).addClasses(["rayde-lsp-inactive"]);
		else if (server.state == "starting" || server.state == "restarting") ashui.css.Identity.of(picture.tree, picture.node.id).addClasses(["rayde-lsp-working"]);
		return <tooltip id="rayde-lsp-tooltip" label={description} side="top"><dropdown-menu side="top" id="rayde-lsp-menu">
			<dropdown-menu-trigger id="rayde-lsp-status" variant={Ghost} class="rayde-status-item rayde-lsp-status">
				{picture}<text>{label}</text>
			</dropdown-menu-trigger>
			<dropdown-menu-content>
				<dropdown-menu-label><text>${description}</text></dropdown-menu-label>
				<dropdown-menu-item id="rayde-lsp-start" disabled={running || server.state == "closing"} onSelect={() -> languageServers.control(server.id, "start")}>Start</dropdown-menu-item>
				<dropdown-menu-item id="rayde-lsp-restart" disabled={server.state == "closing"} onSelect={() -> languageServers.control(server.id, "restart")}>Restart</dropdown-menu-item>
				<dropdown-menu-item id="rayde-lsp-stop" disabled={!running} onSelect={() -> languageServers.control(server.id, "stop")}>Stop</dropdown-menu-item>
				<dropdown-menu-separator/>
				<dropdown-menu-item id="rayde-lsp-settings" onSelect={() -> openSettings("extensions")}>Language Server Settings…</dropdown-menu-item>
				<dropdown-menu-item id="rayde-lsp-output" onSelect={() -> showLanguageOutput(server.owner)}>Show Output</dropdown-menu-item>
			</dropdown-menu-content>
		</dropdown-menu></tooltip>;
	}

	function showLanguageOutput(owner:String):Void {
		var extension = Lambda.find(extensionManager.extensions, entry -> entry.connection.file == owner);
		if (extension != null) {
			outputChannel.set("ext:" + extension.installed.id);
			refreshExtensionOutput();
		}
		showPanel("console");
		ashui.animation.AnimationScheduler.main.after(.01, () -> revealExtensionOutput());
	}

	/** Opens and closes the bottom panel; lit while it is open. */
	function panelItem(on:Bool):Element {
		var item = <div id="rayde-panel-toggle" class="rayde-status-item action flex" onClick={_ -> togglePanel()}><icon document={Icons.LAYOUT_BOTTOM_LINE} class="size-3.5"/></div>;
		if (on)
			ashui.css.Identity.of(item.tree, item.node.id).setAttribute("data-on", "");
		return <tooltip label={"Toggle panel (" + (Sys.systemName() == "Mac" ? "⌘" : "Ctrl+") + "J)"} side="top">{item}</tooltip>;
	}

	function problemCounts(list:Array<Diagnostic>):Element {
		var errors = Lambda.count(list, p -> p.severity == 1), warnings = Lambda.count(list, p -> p.severity == 2);
		return <tooltip label="Problems in the open files" side="top">
			<div id="rayde-problem-counts" class="rayde-status-item action flex" onClick={_ -> showPanel("problems")}>
				<icon document={Icons.CLOSE_CIRCLE_LINE} class="size-3.5"/><text>${errors}</text>
				<icon document={Icons.ALERT_LINE} class="size-3.5"/><text>${warnings}</text>
			</div>
		</tooltip>;
	}

	/**
	 * Where a run stands, and the Run or Stop that goes with it. Run belongs on
	 * the entry point as a code hint, as VS Code puts it, once the editor can
	 * show hints between lines; until then it sits here.
	 */
	function runStatus(state:String):Element {
		if (props.display.project != null && !props.display.project.runnable) return <div/>;
		var active = state == "building" || state == "running";
		return <div class="flex items-center gap-2">
			<if {state == "building"}><text class="text-text-tertiary">Building</text></if>
			<if {state == "running"}><text class="text-text-tertiary">Running</text></if>
			<if {state == "finished"}><text id="rayde-status" class="text-text-tertiary">${"Exited " + runner.exitCode}</text></if>
			<if {state == "failed"}><text id="rayde-status" class="text-error">Build failed</text></if>
			<if {active}><div id="rayde-stop" class="rayde-status-item action flex text-error" onClick={_ -> stopRun()}><icon document={Icons.STOP_FILL} class="size-3.5"/><text>Stop</text></div>
			<else><div id="rayde-run" class="rayde-status-item action flex" onClick={_ -> run()}><icon document={Icons.PLAY_FILL} class="size-3.5"/><text>Run</text></div></if>
		</div>;
	}
}
