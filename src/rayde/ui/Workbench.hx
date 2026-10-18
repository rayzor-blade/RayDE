package rayde.ui;

import ashui.components.Breadcrumb;
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
import ashui.reactive.Computed;
import ashui.reactive.Signal;
import ashui.input.Events.KeyEvent;
import ashui.ui.Component;
import ashui.types.Style;
import ashui.ui.Ref;
import rayde.build.HxmlFile;
import rayde.lang.Display;
import rayde.run.Runner;
import rayde.ui.BuildSettings;
import rayde.ui.FileTabs;
import rayde.ui.Welcome;
import rayde.ui.CommandCenter;

using StringTools;

typedef WorkbenchProps = {
	display:Display,
	/** The project's name, as the title bar shows it. */
	name:String,
	/** The runtime the project runs on, as its profile names it: ash or rayzor. */
	?runtime:String
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
class Workbench extends Component<WorkbenchProps> {
	/** The activity bar's width, and the Explorer's beside it: the side panel holds both. */
	static inline var ACTIVITY = 48.;

	static inline var EXPLORER_WIDTH = 260.;

	/** The page of the build form, which a tab holds in place of a file. */
	public static inline var BUILD = "rayde:build";

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

	/** The build file as the form edits it, read when the form opens. */
	var buildModel:Null<HxmlFile>;

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

	/** The tab shown below the editor: problems or console, which the panel calls Output. */
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

	/** Opens `file` in a tab, or brings its tab forward, and checks it. */
	public function openFile(file:String):Void {
		if (open.get().indexOf(file) < 0)
			open.set(open.get().concat([file]));
		active.set(file);
		if (file == BUILD)
			return;
		remember(file);
		check(file);
	}

	/** Opens the build form in a tab, or brings it forward, reading the build file as it is now. */
	public function openBuild():Void {
		if (props.display.hxml == null)
			return;
		if (open.get().indexOf(BUILD) < 0)
			buildModel = HxmlFile.read(props.display.hxml);
		openFile(BUILD);
	}

	/** The size of the element a selector finds, for tests. */
	public function boundsOf(selector:String):Null<ashui.layout.Bounds> {
		var found = ashui.css.Css.query(tree, this.node.id, selector);
		return found.length == 0 ? null : tree.getBounds(new ashui.layout.Node(found[0]));
	}

	/** The language layer the workbench asks, for tests that look at what it was given. */
	public function display():Display
		return props.display;

	/** The build file the form is editing; null while the form is not open. */
	public function buildFile():Null<HxmlFile>
		return buildModel;

	/** What the form wrote to the build file is now the project's: the compiler reads it, the Explorer and the problems follow it. */
	public function buildChanged():Void {
		props.display.reload();
		buildRevision.set(buildRevision.get() + 1);
		for (file in open.get())
			if (file != BUILD)
				check(file);
	}

	/** Closes `file`'s tab, keeping what was edited in it; the tab beside it comes forward. */
	public function closeFile(file:String):Void {
		var files = open.get(), at = files.indexOf(file);
		if (at < 0)
			return;
		var rest = files.copy();
		rest.splice(at, 1);
		if (active.get() == file)
			active.set(rest.length == 0 ? "" : rest[at < rest.length ? at : rest.length - 1]);
		open.set(rest);
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

	/** The file of the build's main class, when the build names one and a source folder has it. */
	function mainFile():Null<String> {
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
		var file = active.get() == BUILD && props.display.hxml != null ? props.display.hxml : active.get();
		if (file == "")
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
				</dropdown-menu-content>
			</dropdown-menu>
		</tooltip>;
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

	/** The commands the center lists after `>`. */
	function actions():Array<CenterAction> {
		var mod = Sys.systemName() == "Mac" ? "⌘" : "Ctrl+";
		return [
			{id: "run", label: "Run", icon: Icons.PLAY_FILL, shortcut: "F5", run: run},
			{id: "stop", label: "Stop", icon: Icons.STOP_FILL, shortcut: "⇧F5", run: stopRun},
			{id: "save", label: "Save All", icon: Icons.SAVE_3_LINE, shortcut: mod + "S", run: saveAll},
			{id: "close", label: "Close Tab", icon: Icons.CLOSE_LINE, shortcut: mod + "W", run: () -> if (active.get() != "") closeFile(active.get())},
			{id: "definition", label: "Go to Definition", icon: Icons.CORNER_DOWN_RIGHT_LINE, shortcut: "F12", run: goToDefinition},
			{id: "build", label: "Open Build Settings", icon: Icons.SETTINGS_3_LINE, run: openBuild},
			{id: "problems", label: "Show Problems", icon: Icons.CLOSE_CIRCLE_LINE, run: () -> showPanel("problems")},
			{id: "output", label: "Show Output", icon: Icons.TERMINAL_BOX_LINE, run: () -> showPanel("console")},
			{id: "panel", label: "Toggle Panel", icon: Icons.LAYOUT_BOTTOM_LINE, shortcut: (Sys.systemName() == "Mac" ? "⌘" : "Ctrl+") + "J", run: togglePanel},
			{id: "explorer", label: "Toggle Explorer", icon: Icons.FOLDERS_LINE, run: toggleExplorer}
		];
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
	}

	/** Writes every edited buffer to its file: a build reads the files, so it should see them as they are in the editor. */
	public function saveAll():Void {
		for (file in dirty.get())
			sys.io.File.saveContent(file, buffer(file).get());
		if (dirty.get().length > 0)
			dirty.set([]);
	}

	/** Saves what is edited, then builds the project and runs it. */
	public function run():Void {
		saveAll();
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
		if (file == BUILD)
			return;
		var found = try props.display.diagnostics(file, buffer(file).get()) catch (_:Dynamic) [];
		problems.set([for (p in problems.get()) if (p.file != file) p].concat(found));
	}

	/** VS Code's keys: Go to file, Commands, Go to line, Save, Close tab, Go to definition, Run and Stop. */
	function key(e:KeyEvent):Void {
		if (e.defaultPrevented)
			return;
		var command = e.superKey || e.control;
		switch e.key {
			case Character("p") | Character("P") if (command && e.shift):
				openCenter(">");
			case Character("p") | Character("P") if (command):
				openCenter();
			case Character("g") | Character("G") if (command):
				openCenter(":");
			case Character("s") | Character("S") if (command):
				saveAll();
			case Character("w") | Character("W") if (command && active.get() != ""):
				closeFile(active.get());
			case Character("j") | Character("J") if (command):
				togglePanel();
			case Named(F12):
				goToDefinition();
			case Named(F5) if (e.shift):
				stopRun();
			case Named(F5):
				run();
			case _:
				return;
		}
		e.preventDefault();
	}

	function runtime():String
		return props.runtime == null ? "ash" : props.runtime;

	function render():Element {
		runner = new Runner(props.display);
		loadRecent();
		new ashui.reactive.Watch(() -> problemsHeight.get(), h -> if (h > 40) panelHeight = h);
		new ashui.reactive.Watch(() -> panelShown.get(), shown -> markPanel(shown));
		new ashui.reactive.Watch(() -> {
			active.get();
			folderStates.get();
			for (open in folderOpen)
				open.get();
			treeSelected.get();
			0;
		}, _ -> keepSelection(), (_, _) -> false);
		return <div id="rayde" widthPercent={1} heightPercent={1} class="flex flex-col bg-background text-text-primary" onKeyDown={key}>
			${titleBar()}
			<div class="flex flex-1 min-h-0 px-2">
				<resizable id="rayde-columns" class="flex-1 min-h-0">
					<resizable-panel size={treeWidth} minSize={ACTIVITY} maxSize={ACTIVITY + 480}>${sideBar()}</resizable-panel>
					<resizable-panel minSize={320}>
						<resizable ref={rowsRef} id="rayde-rows" direction="vertical" class="flex-1 min-h-0">
							<resizable-panel minSize={160}>${editorCard()}</resizable-panel>
							<resizable-panel size={problemsHeight} minSize={0} maxSize={480}>${bottomCard()}</resizable-panel>
						</resizable>
					</resizable-panel>
				</resizable>
			</div>
			${statusBar()}
			<command-center opened={quickOpen} request={centerRequest} anchor={pill} files={recentFiles} root={props.display.cwd} actions={actions()}
				onOpenFile={path -> openFile(path)} onLine={goToLine}/>
		</div>;
	}

	/** The project in a pill in the middle, which opens the command center; the window has its own title and icon. */
	function titleBar():Element {
		var hint = Sys.systemName() == "Mac" ? "⌘P" : "Ctrl+P";
		pill = <div id="rayde-project" class="rayde-pill flex items-center gap-2 px-3 cursor-pointer" width={420} height={26} onClick={_ -> if (quickOpen.get()) quickOpen.set(false) else openCenter()}>
			<icon document={Icons.FOLDER_3_LINE} class="rayde-pill-icon size-3.5"/>
			<text class="text-xs flex-1">${props.name}</text>
			<text class="rayde-pill-hint text-xs">${hint}</text>
		</div>;
		return <div id="rayde-bar" class="flex items-center px-4 shrink-0" height={40}>
			<div class="flex-1"/>
			<tooltip label={"Search files and commands in " + props.display.cwd} side="bottom">{pill}</tooltip>
			<div class="flex-1"/>
		</div>;
	}

	/** The side panel: the activity bar and the Explorer beside it, in one card. */
	function sideBar():Element
		return <div id="rayde-side" class="rayde-card panel flex flex-1 min-h-0">
			${activityBar()}
			<for {k in [{shown: explorerShown.get(), build: buildRevision.get()}]}>${explorer(k.shown)}</for>
		</div>;

	/** Views down the left edge of the side panel; the Explorer is the one there is, and its icon folds the Explorer away and brings it back. */
	function activityBar():Element
		return <div id="rayde-activity" class="flex flex-col items-center shrink-0 gap-1 py-2" width={ACTIVITY}>
			<for {shown in [explorerShown.get()]}>${explorerItem(shown)}</for>
			<div class="flex-1"/>
			<for {on in [active.get() == BUILD]}>${buildItem(on)}</for>
		</div>;

	function buildItem(on:Bool):Element {
		var item = <div id="rayde-activity-build" class="rayde-activity-item flex" onClick={_ -> openBuild()}>
			<icon document={Icons.SETTINGS_3_LINE} class="size-5"/>
		</div>;
		if (on)
			ashui.css.Identity.of(item.tree, item.node.id).setAttribute("data-on", "");
		return <tooltip label="Build settings" side="right">{item}</tooltip>;
	}

	function explorerItem(shown:Bool):Element {
		var item = <div id="rayde-activity-explorer" class="rayde-activity-item flex" onClick={_ -> toggleExplorer()}>
			<icon document={Icons.FOLDERS_LINE} class="size-5"/>
		</div>;
		if (shown)
			ashui.css.Identity.of(item.tree, item.node.id).setAttribute("data-on", "");
		return <tooltip label="Explorer" side="right">{item}</tooltip>;
	}

	function explorer(shown:Bool):Element {
		if (!shown)
			return <div/>;
		return <div id="rayde-files" class="rayde-explorer flex flex-col flex-1 min-w-0 min-h-0">
			<div class="flex items-center px-3 shrink-0" height={36}><text class="rayde-heading">Explorer</text></div>
			<div class="flex flex-col flex-1 min-h-0 overflow-auto pr-2 pb-2">
				<tree-view id="rayde-tree" selected={treeSelected} onSelect={v -> if (v.endsWith(".hx")) openFile(v) else if (v == props.display.hxml) openBuild()}>
					<tree-item value={props.display.cwd} label={props.name} icon={Icons.FOLDER_OPEN_LINE} expanded={folderState(props.display.cwd, true)}>${buildRow()}{folders()}</tree-item>
				</tree-view>
			</div>
		</div>;
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
		if (file == BUILD && props.display.hxml != null)
			return props.display.hxml;
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
		var args = props.display.args, out = [];
		for (i in 0...args.length - 1)
			if (args[i] == "-cp" || args[i] == "--class-path") {
				var dir = haxe.io.Path.isAbsolute(args[i + 1]) ? args[i + 1] : haxe.io.Path.join([props.display.cwd, args[i + 1]]);
				if (sys.FileSystem.exists(dir) && sys.FileSystem.isDirectory(dir))
					out.push({label: args[i + 1], dir: dir});
			}
		return out;
	}

	/** The build file in the tree, which opens the form and not the text. */
	function buildRow():Element {
		if (props.display.hxml == null)
			return <div/>;
		return <tree-item value={props.display.hxml} label={haxe.io.Path.withoutDirectory(props.display.hxml)} icon={Icons.SETTINGS_3_LINE}/>;
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
				else if (name.endsWith(".hx"))
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
			else if (name.endsWith(".hx"))
				children.push(<tree-item value={path} label={name} icon={Icons.HAXE}/>);
		}
		return <tree-item value={dir} label={label} icon={Icons.FOLDER_LINE} expanded={folderState(dir, expanded)}>{children}</tree-item>;
	}

	/** The open files' tabs, the path to the file in front, and its editor; with nothing open, the welcome page alone. */
	function editorCard():Element
		return <div id="rayde-editor-card" class="rayde-card flex flex-col flex-1 min-h-0">
			<for {has in [open.get().length > 0]}>${tabStrip(has)}</for>
			<for {files in [open.get()]}>${editors(files)}</for>
		</div>;

	function tabLabel(file:String):String
		return file == BUILD ? haxe.io.Path.withoutDirectory(props.display.hxml) : haxe.io.Path.withoutDirectory(file);

	function tabIcon(file:String):ashui.svg.SvgDocument
		return file == BUILD ? Icons.SETTINGS_3_LINE : Icons.HAXE;

	function tabStrip(has:Bool):Element {
		if (!has)
			return <div/>;
		return <file-tabs files={open} active={active} dirty={dirty} onClose={closeFile} label={tabLabel} icon={tabIcon} trailing={editorMenu()}/>;
	}

	function editors(files:Array<String>):Element {
		if (files.length == 0)
			return welcome();
		return <div class="flex flex-col flex-1 min-h-0">
			<for {file in [active.get()]}>${breadcrumb(file)}</for>
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
		if (file == BUILD)
			return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs([haxe.io.Path.withoutDirectory(props.display.hxml), "Build"])}</breadcrumb>;
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
		if (file == BUILD)
			return <tabs-content value={file} class="flex-1 min-h-0">
				<build-settings file={buildModel} root={props.display.cwd} onChanged={buildChanged}/>
			</tabs-content>;
		return pageOfFile(file);
	}

	function pageOfFile(file:String):Element
		return <tabs-content value={file} class="flex-1 min-h-0">
			<code-editor ref={editorRef(file)} id={"rayde-editor-" + haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(file))} value={buffer(file)} language="haxe"
				lineNumbers={true} folding={true} indentGuides={true} highlightBrackets={true} tabSize={4} insertSpaces={false} onInput={_ -> edited(file)}
				class="flex-1 min-h-0"/>
		</tabs-content>;

	/** Problems and the Output of a run, as VS Code's panel names them. */
	function bottomCard():Element
		return <div id="rayde-panel" class="rayde-card panel relative flex flex-col flex-1 min-h-0">
			<tabs id="rayde-bottom" value={bottom} size={Sm} class="flex-1 min-h-0 px-2 pt-2">
				<tabs-list class="shrink-0">
					<tabs-trigger id="rayde-tab-problems" value="problems">Problems</tabs-trigger>
					<tabs-trigger id="rayde-tab-console" value="console">Output</tabs-trigger>
				</tabs-list>
				<tabs-content value="problems" class="flex-1 min-h-0 pt-1"><for {list in [problems.get()]}>${problemsPane(list)}</for></tabs-content>
				<tabs-content value="console" class="flex-1 min-h-0 pt-1">
					<code-view id="rayde-console" value={consoleText} language="plain" lineNumbers={false} folding={false} class="flex-1 min-h-0"/>
				</tabs-content>
			</tabs>
			<div class="flex items-center gap-1" position={Absolute} right={8} top={6}>
				<tooltip label="Close panel" side="top"><button id="rayde-panel-close" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> closePanel()}><icon document={Icons.CLOSE_LINE} class="size-4"/></button></tooltip>
			</div>
		</div>;

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
