package rayde.ui;

import ashui.components.Breadcrumb;
import ashui.components.ContextMenu;
import ashui.components.ContextMenu.ContextMenuTrigger;
import ashui.components.Button;
import ashui.components.DropdownMenu;
import ashui.components.CodeEditor;
import ashui.components.CodeView;
import ashui.components.Icon;
import ashui.components.Resizable;
import ashui.components.Tabs;
import ashui.components.Tooltip;
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
import rayde.ext.Manifest.ViewDecl;
import rayde.files.FileOps;
import rayde.ext.Studio;
import rayde.keys.Chord;
import rayde.keys.KeyBindings;
import rayde.keys.Keymaps;
import rayde.lang.Display;
import rayde.run.LibraryManager;
import rayde.run.Runner;
import rayde.settings.Appearance;
import rayde.settings.Store;
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
	/** The window's controls: the app's window; without one the controls act on nothing and keep their own state, as in a test. */
	?chrome:WindowChrome
};

/** A part of the layout an extension view takes: its icon in the activity bar, and where its view is drawn. */
private typedef Container = {id:String, title:String, icon:ashui.svg.SvgDocument, location:String, view:ViewDecl};

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

	/** The view an editor tab of the extension shows. */
	function viewOfTab(file:String):Null<ViewDecl>
		return extension == null ? null : extension.viewOf(file == EXTENSION_TAB ? "main" : file.substr(EXTENSION_TAB.length + 1));

	/** A page of the workbench that is not a file: Settings, a view of the extension in a tab, or a tab an extension presented. */
	static function isVirtual(file:String):Bool
		return file == SETTINGS || isViewTab(file) || isTab(file);

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

	final centerRequest = Signal.make(({text: "", serial: 0} : CenterRequest));

	/** A line the status bar shows for a few seconds: what a command could not do. */
	final notice = Signal.make("");

	final buffers = new Map<String, Signal<String>>();
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

	/** The extensions open in the Studio, by their main file, and the one of the file in front, if it is one. */
	final studios = new Map<String, Studio>();

	final activeStudio = Signal.make((null : Null<Studio>));

	/** The Preview's width beside the code. */
	final previewWidth = Signal.make(440.);

	/** The tab shown below the editor: problems, console (which the panel calls Output), terminal or extension. */
	public final bottom = Signal.make("problems");

	/** What the build and the program have printed, and where the run is: idle, building, running, finished or failed. */
	final consoleText = Signal.make("");

	final runState = Signal.make("idle");
	public var runner(default, null):Null<Runner>;
	var seen = -1;
	var pill:Element;
	var lastBuild:Null<Array<Diagnostic>>;

	public function new(props:WorkbenchProps) {
		explorerShown = Computed.make(() -> treeWidth.get() > ACTIVITY + 8);
		panelShown = Computed.make(() -> problemsHeight.get() > 40);
		super(props);
	}

	/** Opens what a project opens with: for an extension, its main script, with its view shown where the config puts it. */
	public function openProject():Void {
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
					openFile(viewTabId(c.view.id));
				case _:
			}
		if (main != null)
			active.set(main);
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
		var files = open.get(), at = files.indexOf(file);
		if (at < 0)
			return;
		var rest = files.copy();
		rest.splice(at, 1);
		var studio = studios.get(file);
		if (studio != null) {
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
		return file == "" || isVirtual(file) ? null : file;

	/** Adds the tabs of an extension to the editor, and takes those it has unmounted away. */
	function syncTabs(studio:Studio, list:Array<TabView>):Void {
		var mine = TAB + studio.file + "#", ids = [for (t in list) mine + t.root];
		var before = open.get();
		var kept = [for (f in before) if (!StringTools.startsWith(f, mine) || ids.indexOf(f) >= 0) f];
		var added = [for (i in ids) if (before.indexOf(i) < 0) i];
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

	/** A file the Explorer lists and the center finds: Haxe, and an extension's scripts; for an extension project, its text files too. */
	function isSource(path:String):Bool {
		if (path.endsWith(".hx") || path.endsWith(".rays"))
			return true;
		return extension != null && (path.endsWith(".json") || path.endsWith(".svg") || path.endsWith(".css") || path.endsWith(".md"));
	}

	/** The file of the build's main class, when the build names one and a source folder has it; for an extension, its main script. */
	function mainFile():Null<String> {
		if (extension != null)
			return sys.FileSystem.exists(extension.mainPath()) ? extension.mainPath() : null;
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
		openFile(file);
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

	function editorOf(file:String):Null<CodeEditor> {
		var ref = editorRefs.get(file);
		return ref == null ? null : ref.get();
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
		var file = active.get(), offset = caret(file);
		if (file == "" || offset < 0)
			return;
		var found = try props.display.definition(file, offset, buffer(file).get()) catch (_:Dynamic) [];
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
		open.set(file == "" ? [] : [file]);
	}

	/** Closes the tabs with nothing unsaved; the one in front goes with them unless it has edits. */
	public function closeSaved():Void {
		var keep = [for (f in open.get()) if (dirty.get().indexOf(f) >= 0) f];
		if (keep.indexOf(active.get()) < 0)
			active.set(keep.length == 0 ? "" : keep[0]);
		open.set(keep);
	}

	public function closeAll():Void {
		active.set("");
		open.set([]);
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
		var entries = extension == null || isVirtual(file) || file == "" ? [] : extension.menuFor("editor/title", file, "file");
		if (entries.length == 0)
			return <div/>;
		var items:Array<Element> = [<dropdown-menu-separator/>];
		for (e in entries) {
			var icon = ViewIcons.named(extension, e.icon), keys = bindings.label(extensionKey(e.command));
			var label = icon == null ? <text>${e.title}</text> : <div class="flex items-center justify-between gap-3 flex-1 min-w-0"><text>${e.title}</text><icon document={icon} class="size-4 shrink-0 text-text-secondary"/></div>;
			items.push(<dropdown-menu-item id={"rayde-menu-ext-" + e.command} shortcut={keys} onSelect={() -> runExtensionCommand(e.command, file)}>${label}</dropdown-menu-item>);
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
		var t = Terminal.open(100, 12, props.display.cwd, profile.program, profile.args);
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
				ashui.css.Identity.of(rows.tree, rows.node.id).setAttribute("data-closed", shown ? null : "");
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
			{id: "run", label: "Run", icon: Icons.PLAY_FILL, run: run},
			{id: "stop", label: "Stop", icon: Icons.STOP_FILL, run: stopRun},
			{id: "save", label: "Save All", icon: Icons.SAVE_3_LINE, run: saveAll},
			{id: "close", label: "Close Tab", icon: Icons.CLOSE_LINE, run: () -> if (active.get() != "") closeFile(active.get())},
			{id: "definition", label: "Go to Definition", icon: Icons.CORNER_DOWN_RIGHT_LINE, run: goToDefinition},
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

	/** The id a command of the extension has among the workbench's, which its key is bound by. */
	static function extensionKey(command:String):String
		return "ext." + command;

	/** The commands the extension contributes, run by the extension on the file the Explorer or the editor has in front. */
	function contributedCommands():Array<CenterAction>
		return extension == null ? [] : [
			for (c in extension.commands)
				{id: extensionKey(c.id), label: c.title, icon: ViewIcons.named(extension, c.icon) ?? Icons.PUZZLE_LINE, run: () -> runExtensionCommand(c.id, (explorerFocused() ? selectedPath() : null) ?? realFile(active.get()))}
		];

	/** Runs a command of the extension with `{path, kind}` of what it applies to; `kind` is file or folder, null with no path. */
	function runExtensionCommand(command:String, path:Null<String>):Void {
		var studio = extensionStudio();
		if (studio == null)
			return;
		var kind:Null<String> = path == null ? null : sys.FileSystem.exists(path) && sys.FileSystem.isDirectory(path) ? "folder" : "file";
		studio.command(command, {path: path, kind: kind});
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
		var b = buffers.get(file);
		if (b == null) {
			b = Signal.make(sys.io.File.getContent(file));
			buffers.set(file, b);
		}
		return b;
	}

	/** Records that `file`'s buffer has changed since it was last written, and checks it as it now is. */
	public function edited(file:String):Void {
		if (dirty.get().indexOf(file) < 0)
			dirty.set(dirty.get().concat([file]));
		check(file);
		var studio = studios.get(file);
		if (studio != null)
			studio.edited();
		else if (extension != null && isExtension(file))
			extensionStudio().edited();
		emit("file.changed", {path: file}, .3);
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

	/** The Studio for an extension's main file, started the first time it is asked for. */
	function studioOf(file:String):Studio {
		var studio = studios.get(file);
		if (studio != null)
			return studio;
		var name = StringTools.replace(relative(file), "/", "_");
		var own = extension != null && extension.mainPath() == file ? extension : null;
		studio = new Studio(file, haxe.io.Path.join([props.display.cwd, ".rayde", "studio", name]), () -> buffer(file).get(), tree, own);
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

	/** Resolves a path an extension gave against the project, refusing one outside it. */
	function projectPath(path:String):String {
		var full = haxe.io.Path.normalize(haxe.io.Path.isAbsolute(path) ? path : haxe.io.Path.join([props.display.cwd, path]));
		if (!FileOps.inside(props.display.cwd, full))
			throw "That is outside the project.";
		return full;
	}

	/** What an extension may ask of the workbench through `rayde.workspace`. */
	function services():Services
		return {
			readFile: p -> {
				var full = projectPath(p);
				buffers.exists(full) ? buffers.get(full).get() : sys.FileSystem.exists(full) && !sys.FileSystem.isDirectory(full) ? sys.io.File.getContent(full) : null;
			},
			activeFile: () -> realFile(active.get()),
			root: () -> props.display.cwd,
			openFile: p -> openFile(projectPath(p)),
			writeFile: (p, text) -> {
				var full = projectPath(p);
				sys.io.File.saveContent(full, text);
				var b = buffers.get(full);
				if (b != null)
					b.set(text);
				dirty.set([for (d in dirty.get()) if (d != full) d]);
				refreshExplorer();
			},
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
			var studio = studios.get(file);
			if (studio != null && !studio.live.get())
				studio.reload();
			emit("file.saved", {path: file});
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
		consoleText.set(runner.console);
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
		if (isVirtual(file) || !StringTools.endsWith(file, ".hx"))
			return;
		var found = try props.display.diagnostics(file, buffer(file).get()) catch (_:Dynamic) [];
		problems.set([for (p in problems.get()) if (p.file != file) p].concat(found));
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
		terminalSettings = Settings.read(props.display.cwd);
		appearance = Appearance.read(props.display.cwd);
		chrome = props.chrome != null ? props.chrome : new WindowChrome();
		windowStyle.set(WindowControls.styleFor(appearance.windowControls));
		bindings = KeyBindings.read(props.display.cwd, Sys.systemName() == "Mac");
		libraries = new LibraryManager(props.display.cwd);
		containers = makeContainers();
		commandList = commands();
		refreshShortcuts();
		loadRecent();
		new ashui.reactive.Watch(() -> problemsHeight.get(), h -> if (h > 40) panelHeight = h);
		new ashui.reactive.Watch(() -> active.get(), file -> {
			activeStudio.set(extension != null ? extensionStudio() : studios.get(file));
			emit("active.changed", {path: realFile(file)});
		});
		new ashui.reactive.Watch(() -> panelShown.get(), shown -> markPanel(shown));
		// The controls go grey while another window is in front.
		new ashui.reactive.Watch(() -> ashui.input.WindowState.active.get(), on -> chrome.focused.set(on));
		// The terminal starts when its tab is first in view, not when RayDE does.
		new ashui.reactive.Watch(() -> {
			bottom.get();
			panelShown.get();
			0;
		}, _ -> if (bottom.get() == "terminal" && panelShown.get())
			ensureTerminal(), (_, _) -> false);
		Owner.onCleanup(() -> for (s in sessions)
			s.terminal.close());
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
			<command-center opened={quickOpen} request={centerRequest} anchor={pill} files={recentFiles} root={props.display.cwd} actions={commandList} tasks={taskChoices}
				onOpenFile={path -> openFile(path)} onLine={goToLine}/>
		</div>;
		// A window of its own, not filling the screen, has rounded corners (but Windows's) and, where the system draws no frame, an outline.
		// They are on a card inside the root, which is the whole of what the window draws and cannot be clipped.
		var root = <div id="rayde" widthPercent={1} heightPercent={1} class="flex flex-col text-text-primary" onKeyDown={key}>{window}</div>;
		var identity = ashui.css.Identity.of(window.tree, window.node.id);
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
	function sideBar():Element
		return <div id="rayde-side" class="rayde-card panel flex flex-1 min-h-0">
			${activityBar()}
			<for {k in [{shown: explorerShown.get(), build: buildRevision.get(), view: sideView.get()}]}>${sideBody(k.shown, k.view)}</for>
		</div>;

	/** What fills the side panel beside the activity bar: the Explorer, or the view of an extension that took its place. */
	function sideBody(shown:Bool, view:String):Element {
		if (!shown)
			return <div/>;
		var c = Lambda.find(containers, c -> c.id == view && c.location == "sidebar");
		return c == null ? explorer(shown) : extensionBody(c, "rayde-explorer");
	}

	/** An extension's view in the part of the layout it was given, under its own heading. */
	function extensionBody(c:Container, style:String):Element {
		var studio = extensionStudio();
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
			<for {k in [{shown: explorerShown.get(), view: sideView.get(), secondary: secondaryWidth.get(), panel: panelShown.get() ? bottom.get() : "", file: active.get()}]}>${containerItems(k.shown, k.view, k.secondary, k.panel, k.file)}</for>
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
	function containerItems(shown:Bool, view:String, secondary:Float, panel:String, file:String):Element {
		var items:Array<Element> = [activityItem("rayde-activity-explorer", "Explorer", Icons.FOLDERS_LINE, shown && view == "explorer", chooseExplorer)];
		for (c in containers) {
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
		switch c.location {
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
				openFile(viewTabId(c.view.id));
		}
	}

	/** What decides where the extension's views are and how their headers look: when it changes, the layout is made again. */
	static function layoutKey(m:Manifest):String
		return haxe.Json.stringify(m.views);

	/** The form changed the extension's config, which has been read again: the Studio and, if the view moved or looks different, the layout follow. */
	function extensionChanged(m:Manifest):Void {
		var before = extension == null ? "" : layoutKey(extension);
		extension = m;
		var studio = extensionStudio();
		if (studio != null)
			studio.useManifest(m);
		commandList.splice(0, commandList.length);
		for (a in commands())
			commandList.push(a);
		refreshShortcuts();
		bindingsRevision.set(bindingsRevision.get() + 1);
		if (layoutKey(m) == before)
			return;
		containers = makeContainers();
		if (!Lambda.exists(containers, c -> c.id == sideView.get() && c.location == "sidebar")) {
			var first = Lambda.find(containers, c -> c.location == "sidebar");
			sideView.set(first == null ? "explorer" : first.id);
		}
		layoutRevision.set(layoutRevision.get() + 1);
	}

	function makeContainers():Array<Container> {
		var m = extension;
		return m == null ? [] : [for (v in m.views) {id: v.id == "main" ? "ext" : "ext-" + v.id, title: v.title, icon: ViewIcons.ofView(m, v), location: v.location, view: v}];
	}

	/** The Studio of this project's extension: its main script, run with the project's config. */
	function extensionStudio():Null<Studio>
		return extension == null ? null : studioOf(extension.mainPath());

	function explorer(shown:Bool):Element {
		if (!shown)
			return <div/>;
		var root = tagged(<tree-item value={props.display.cwd} label={props.name} icon={Icons.FOLDER_OPEN_LINE} expanded={folderState(props.display.cwd, true)}>${buildRow()}{folders()}</tree-item>, props.display.cwd);
		return <div id="rayde-files" class="rayde-explorer flex flex-col flex-1 min-w-0 min-h-0">
			<div class="flex items-center px-3 shrink-0" height={36}><text class="rayde-heading">Explorer</text></div>
			<context-menu ref={explorerMenu} id="rayde-explorer-menu">
				<context-menu-trigger id="rayde-explorer-trigger">
					<div class="flex flex-col flex-1 min-h-0 overflow-auto pr-2 pb-2" onPointerDown={explorerPress}>
						<tree-view id="rayde-tree" selected={treeSelected} onSelect={v -> if (Manifest.isManifest(v)) openSettings("extension") else if (isSource(v)) openFile(v) else if (v == props.display.hxml) openBuild()}>${root}</tree-view>
					</div>
				</context-menu-trigger>
				<context-menu-content id="rayde-explorer-menu-content"><for {state in [{target: menuTarget.get(), keys: bindingsRevision.get(), held: clipboardRevision.get()}]}>${explorerItems(state.target)}</for></context-menu-content>
			</context-menu>
		</div>;
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

	/** An item's label, with its icon at the right end. */
	function itemLabel(label:String, icon:Null<ashui.svg.SvgDocument>):Element {
		if (icon == null)
			return <text>${label}</text>;
		return <div class="flex items-center justify-between gap-3 flex-1 min-w-0">
			<text>${label}</text>
			<icon document={icon} class="size-4 shrink-0 text-text-secondary"/>
		</div>;
	}

	function menuItem(label:String, command:Null<String>, run:Void->Void, enabled = true, ?icon:ashui.svg.SvgDocument):Element {
		var keys = command == null ? null : bindings.label(command);
		return <context-menu-item id={menuId(label)} shortcut={keys} disabled={!enabled} onSelect={run}>${itemLabel(label, icon)}</context-menu-item>;
	}

	function dangerItem(label:String, command:Null<String>, run:Void->Void):Element {
		var keys = command == null ? null : bindings.label(command);
		return <context-menu-item id={menuId(label)} shortcut={keys} destructive={true} onSelect={run}>${itemLabel(label, null)}</context-menu-item>;
	}

	/** The items of the Explorer's menu for a file, a folder or the project's own folder. */
	function explorerItems(path:String):Element {
		var folder = path != "" && sys.FileSystem.exists(path) && sys.FileSystem.isDirectory(path), top = path == props.display.cwd;
		var items:Array<Element> = [];
		var contributed = extension == null ? [] : extension.menuFor("explorer/context", path, folder ? "folder" : "file");
		var icons = [for (c in contributed) extension == null ? null : ViewIcons.named(extension, c.icon)];
		if (!folder && path != "")
			items.push(menuItem("Open", null, () -> if (isSource(path)) openFile(path) else if (Manifest.isManifest(path)) openSettings("extension")));
		if (folder) {
			items.push(menuItem("New File…", "newfile", () -> askCreate(path, false)));
			items.push(menuItem("New Folder…", "newfolder", () -> askCreate(path, true)));
		}
		if (contributed.length > 0) {
			if (items.length > 0)
				items.push(<context-menu-separator/>);
			for (i => c in contributed)
				items.push(menuItem(c.title, extensionKey(c.command), () -> runExtensionCommand(c.command, path), true, icons[i]));
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
	public function refreshExplorer():Void
		buildRevision.set(buildRevision.get() + 1);

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
		var moved = FileOps.moved(open.get(), from, to);
		for (old => now in FileOps.moved([for (k in buffers.keys()) k], from, to)) {
			buffers.set(now, buffers.get(old));
			buffers.remove(old);
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
		if (extension != null)
			return extension.sourceDirs();
		var args = props.display.args, out = [];
		for (i in 0...args.length - 1)
			if (args[i] == "-cp" || args[i] == "--class-path") {
				var dir = haxe.io.Path.isAbsolute(args[i + 1]) ? args[i + 1] : haxe.io.Path.join([props.display.cwd, args[i + 1]]);
				if (sys.FileSystem.exists(dir) && sys.FileSystem.isDirectory(dir))
					out.push({label: args[i + 1], dir: dir});
			}
		return out;
	}

	/** The build file in the tree, which opens the form and not the text; for an extension, its config file, which opens its form. */
	function buildRow():Element {
		if (extension != null)
			return tagged(<tree-item value={extension.file} label={haxe.io.Path.withoutDirectory(extension.file)} icon={Icons.SETTINGS_3_LINE}/>, extension.file);
		if (props.display.hxml == null)
			return <div/>;
		return tagged(<tree-item value={props.display.hxml} label={haxe.io.Path.withoutDirectory(props.display.hxml)} icon={Icons.SETTINGS_3_LINE}/>, props.display.hxml);
	}

	function folders():Array<Element>
		return [for (cp in classpaths()) folder(cp.dir, cp.label, true)];

	/** The project's files with the open ones first, in the order of their tabs. */
	function recentFiles():Array<String> {
		var all = projectFiles(), open = open.get();
		return [for (f in open) if (all.indexOf(f) >= 0) f].concat([for (f in all) if (open.indexOf(f) < 0) f]);
	}

	/** Every Haxe file under the project's source folders, folder by folder, in name order. */
	function projectFiles():Array<String> {
		var out = [];
		function walk(dir:String):Void {
			var names = sys.FileSystem.readDirectory(dir);
			names.sort(Reflect.compare);
			for (name in names) {
				var path = haxe.io.Path.join([dir, name]);
				if (name.startsWith("."))
					continue;
				if (sys.FileSystem.isDirectory(path))
					walk(path);
				else if (isSource(path))
					out.push(path);
			}
		}
		for (cp in classpaths())
			walk(cp.dir);
		return out;
	}

	function folder(dir:String, label:String, expanded:Bool):Element {
		var names = sys.FileSystem.readDirectory(dir);
		names.sort(Reflect.compare);
		var children:Array<Element> = [];
		for (name in names) {
			var path = haxe.io.Path.join([dir, name]);
			if (name.startsWith("."))
				continue;
			if (sys.FileSystem.isDirectory(path))
				children.push(folder(path, name, false));
			else if (isSource(path))
				children.push(tagged(<tree-item value={path} label={name} icon={fileIcon(path)}/>, path));
		}
		return tagged(<tree-item value={dir} label={label} icon={Icons.FOLDER_LINE} expanded={folderState(dir, expanded)}>{children}</tree-item>, dir);
	}

	/** The open files' tabs, the path to the file in front, and its editor; with nothing open, the welcome page alone. */
	function editorCard():Element
		return <div id="rayde-editor-card" class="rayde-card flex flex-col flex-1 min-h-0">
			<for {has in [open.get().length > 0]}>${tabStrip(has)}</for>
			<for {files in [open.get()]}>${editors(files)}</for>
		</div>;

	function tabLabel(file:String):String
		return isTab(file) ? tabTitle(file) : file == SETTINGS ? "Settings" : isViewTab(file) ? viewTabTitle(file) : haxe.io.Path.withoutDirectory(file);

	function viewTabTitle(file:String):String {
		var v = viewOfTab(file);
		return v == null ? "Extension" : v.title;
	}

	function tabIcon(file:String):ashui.svg.SvgDocument
		return isTab(file) ? (extension != null ? ViewIcons.of(extension) : Icons.PUZZLE_LINE) : file == SETTINGS ? Icons.SETTINGS_3_LINE : isViewTab(file) && viewOfTab(file) != null ? ViewIcons.ofView(extension, viewOfTab(file)) : fileIcon(file);

	/** The icon a file has in the Explorer and on its tab. */
	function fileIcon(file:String):ashui.svg.SvgDocument
		return StringTools.endsWith(file, ".hx") ? Icons.HAXE : isExtension(file) ? Icons.PUZZLE_LINE : Manifest.isManifest(file) ? Icons.SETTINGS_3_LINE : StringTools.endsWith(file, ".md") ? Icons.MARKDOWN_LINE : Icons.BRACES_LINE;

	function tabStrip(has:Bool):Element {
		if (!has)
			return <div/>;
		return <file-tabs files={open} active={active} dirty={dirty} onClose={closeFile} label={tabLabel} icon={tabIcon} trailing={editorMenu()}/>;
	}

	function editors(files:Array<String>):Element {
		if (files.length == 0)
			return welcome();
		return <div class="flex flex-col flex-1 min-h-0">
			<for {file in [active.get() == SETTINGS ? SETTINGS + ":" + settingsCategory.get() : active.get()]}>${breadcrumb(active.get())}</for>
			<tabs id="rayde-tabs" value={active} class="flex-1 min-h-0">
				<tabs-list indicator={false} class="rayde-nolist"/>
				{[for (f in files) page(f)]}
			</tabs>
		</div>;
	}

	function welcome():Element
		return <welcome name={props.name} runtime={runtime()} root={props.display.cwd}
			build={props.display.hxml == null ? "build.hxml" : haxe.io.Path.withoutDirectory(props.display.hxml)} haxe={compilerVersion()}
			sources={[for (cp in classpaths()) cp.label]} files={projectFiles().length} main={mainFile()} recent={recent} problems={problems}
			onOpen={path -> openFile(path)} onFiles={() -> openCenter()} onCommands={() -> openCenter(">")} onRun={run} onBuild={openBuild}/>;

	/** Where `file` sits in the project, folder by folder. */
	function breadcrumb(file:String):Element {
		if (file == SETTINGS)
			return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs(["Settings", SettingsPage.labelOf(SettingsPage.category(settingsCategory.get()), extension)])}</breadcrumb>;
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
		if (isTab(file)) {
			var owner = studios.get(tabStudio(file));
			return <tabs-content value={file} class="flex-1 min-h-0">
				{owner == null ? <div/> : <studio-tab studio={owner} root={tabRoot(file)}/>}
			</tabs-content>;
		}
		if (isViewTab(file)) {
			var studio = extensionStudio();
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
					listening={() -> extension == null ? [] : extensionStudio().listening()}/>
			</tabs-content>;
		return pageOfFile(file);
	}

	/** The grammar the editor highlights `file` by. */
	static function languageOf(file:String):String
		return StringTools.endsWith(file, ".hx") || StringTools.endsWith(file, ".rays") ? "haxe" : StringTools.endsWith(file, ".json") ? "json" : "plain";

	function pageOfFile(file:String):Element {
		if (isExtension(file) && extension == null)
			return studioPage(file);
		return <tabs-content value={file} class="flex-1 min-h-0">${codeEditor(file)}</tabs-content>;
	}

	function codeEditor(file:String):Element {
		var editor = <code-editor ref={editorRef(file)} id={"rayde-editor-" + haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(file))} value={buffer(file)} language={languageOf(file)}
			lineNumbers={true} folding={true} indentGuides={true} highlightBrackets={true} minimap={true} tabSize={4} insertSpaces={false} onInput={_ -> edited(file)}
			class="flex-1 min-h-0"/>;
		holdCaretWhileScrolling(editorRef(file).get());
		return editor;
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
		check = () -> {
			var left = CARET_REST - (haxe.Timer.stamp() - last);
			if (left > 0)
				ashui.animation.AnimationScheduler.main.after(left, check);
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
			ashui.animation.AnimationScheduler.main.after(CARET_REST, check);
		});
	}

	/** An extension: its code, and beside it the Preview of what it draws. */
	function studioPage(file:String):Element {
		var studio = studioOf(file);
		return <tabs-content value={file} class="flex-1 min-h-0">
			<resizable id="rayde-studio-columns" class="flex-1 min-h-0">
				<resizable-panel minSize={200}>${codeEditor(file)}</resizable-panel>
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
				<tabs-content value="problems" class="flex-1 min-h-0 pt-1"><for {list in [problems.get()]}>${problemsPane(list)}</for></tabs-content>
				<tabs-content value="console" class="flex-1 min-h-0 pt-1">
					<code-view id="rayde-console" value={consoleText} language="plain" lineNumbers={false} folding={false} class="flex-1 min-h-0"/>
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
			onExit={code -> say(s.profile.name + " exited with code " + code)} onFocus={() -> noteFocus(id)} reserved={reservedKey}/>;
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
					</dropdown-menu-content>
				</dropdown-menu>
			</div>
			<tooltip label="Kill terminal" side="top"><button id="rayde-terminal-kill" variant={Ghost} size={Icon} class="rayde-panel-button rayde-remove" onClick={_ -> killTerminal()}><icon document={Icons.DELETE_BIN_LINE} class="size-4"/></button></tooltip>
		</div>;
	}

	/** One item for each shell the machine has, with where it is, the default marked. */
	function profileItems():Array<Element>
		return [for (p in Profiles.list()) profileItem(p)];

	function profileItem(p:Profile):Element
		return <dropdown-menu-item id={"rayde-profile-" + p.name} shortcut={p.program} onSelect={() -> newTerminal(p)}>${p.name == defaultProfile().name ? p.name + " (default)" : p.name}</dropdown-menu-item>;

	function problemsPane(list:Array<Diagnostic>):Element
		return <div id="rayde-problems" class="flex flex-col flex-1 min-h-0 overflow-auto">
			<if {list.length == 0}><div class="px-2 py-1"><text class="text-xs text-text-tertiary">No problems in the open files.</text></div></if>
			{[for (p in list) problemRow(p)]}
		</div>;

	function problemRow(p:Diagnostic):Element
		return <div class="rayde-problem flex items-center gap-2 px-2 py-1 cursor-pointer" onClick={_ -> goTo(p.file, p.range.start.line, p.range.start.character)}>
			<if {p.severity == 1}><icon document={Icons.CLOSE_CIRCLE_LINE} class="size-4 text-error"/>
			<else><icon document={Icons.ALERT_LINE} class="size-4 text-warning"/></if>
			<text class="text-xs flex-1 min-w-0">${p.message.split("\n")[0]}</text>
			<text class="text-xs text-text-tertiary">${haxe.io.Path.withoutDirectory(p.file) + " [" + (p.range.start.line + 1) + ", " + (p.range.start.character + 1) + "]"}</text>
		</div>;

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
			<div class="rayde-status-item flex"><text>Haxe</text></div>
		</div>;

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
