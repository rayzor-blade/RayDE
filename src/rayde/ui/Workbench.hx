package rayde.ui;

import ashui.components.Breadcrumb;
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
import ashui.ui.Component;
import rayde.lang.Display;
import rayde.run.Runner;
import rayde.ui.FileTabs;

using StringTools;

typedef WorkbenchProps = {
	display:Display,
	/** The project's name, as the title bar shows it. */
	name:String,
	/** The runtime the project runs on, as its profile names it: ash or rayzor. */
	?runtime:String
};

/**
 * The IDE, laid out as VS Code is: a title bar naming the project, an activity
 * bar, the Explorer, the open files as tabs over a breadcrumb and the code
 * editor, below them the Problems and the Output of a run, and a status bar.
 * Each region is a card with a gap between, each part resizable. What is open,
 * and each buffer as edited, lives here, so the panes can be rebuilt without
 * losing either. `run` keeps its own watch on a build or run; a host that
 * drives the clock itself can call `tick`.
 */
class Workbench extends Component<WorkbenchProps> {
	static inline var EXPLORER_WIDTH = 260.;

	public final open = Signal.make(([] : Array<String>));
	public final active = Signal.make("");
	public final problems = Signal.make(([] : Array<Diagnostic>));

	/** The open files with edits not yet written to disk. */
	public final dirty = Signal.make(([] : Array<String>));

	final buffers = new Map<String, Signal<String>>();
	final treeWidth = Signal.make(EXPLORER_WIDTH);
	final explorerShown:Computed<Bool>;
	final problemsHeight = Signal.make(190.);

	/** The tab shown below the editor: problems or console, which the panel calls Output. */
	public final bottom = Signal.make("problems");

	/** What the build and the program have printed, and where the run is: idle, building, running, finished or failed. */
	final consoleText = Signal.make("");

	final runState = Signal.make("idle");
	public var runner(default, null):Null<Runner>;
	var seen = -1;
	var lastBuild:Null<Array<Diagnostic>>;

	public function new(props:WorkbenchProps) {
		explorerShown = Computed.make(() -> treeWidth.get() > 8);
		super(props);
	}

	/** Opens `file` in a tab, or brings its tab forward, and checks it. */
	public function openFile(file:String):Void {
		if (open.get().indexOf(file) < 0)
			open.set(open.get().concat([file]));
		active.set(file);
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
		bottom.set("console");
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
				bottom.set("problems");
		}
	}

	/** Asks the compiler what is wrong with `file` as it is in the editor. */
	public function check(file:String):Void {
		var found = try props.display.diagnostics(file, buffer(file).get()) catch (_:Dynamic) [];
		problems.set([for (p in problems.get()) if (p.file != file) p].concat(found));
	}

	function runtime():String
		return props.runtime == null ? "ash" : props.runtime;

	function render():Element {
		runner = new Runner(props.display);
		return <div id="rayde" widthPercent={1} heightPercent={1} class="flex flex-col bg-background text-text-primary">
			${titleBar()}
			<div class="flex flex-1 min-h-0 pr-2">
				${activityBar()}
				<resizable id="rayde-rows" direction="vertical" class="flex-1 min-h-0">
					<resizable-panel minSize={160}>
						<resizable id="rayde-columns" class="flex-1 min-h-0">
							<resizable-panel size={treeWidth} minSize={0} maxSize={480}>
								<for {shown in [explorerShown.get()]}>${explorer(shown)}</for>
							</resizable-panel>
							<resizable-panel minSize={320}>${editorCard()}</resizable-panel>
						</resizable>
					</resizable-panel>
					<resizable-panel size={problemsHeight} minSize={96} maxSize={480}>${bottomCard()}</resizable-panel>
				</resizable>
			</div>
			${statusBar()}
		</div>;
	}

	/** The project in a pill in the middle; the window has its own title and icon. */
	function titleBar():Element
		return <div id="rayde-bar" class="flex items-center px-4 shrink-0" height={40}>
			<div class="flex-1"/>
			<tooltip label={"Project in " + props.display.cwd} side="bottom">
				<div id="rayde-project" class="rayde-pill flex items-center justify-center gap-2" width={420} height={26}>
					<icon document={Icons.FOLDER_3_LINE} class="rayde-pill-icon size-3.5"/>
					<text class="text-xs">${props.name}</text>
				</div>
			</tooltip>
			<div class="flex-1"/>
		</div>;

	/** Views down the left edge; the Explorer is the one there is, and its icon folds the Explorer away and brings it back. */
	function activityBar():Element
		return <div id="rayde-activity" class="flex flex-col items-center shrink-0 gap-1 pt-1" width={48}>
			<for {shown in [explorerShown.get()]}>${explorerItem(shown)}</for>
		</div>;

	function explorerItem(shown:Bool):Element {
		var item = <div id="rayde-activity-explorer" class="rayde-activity-item flex" onClick={_ -> treeWidth.set(shown ? 0 : EXPLORER_WIDTH)}>
			<icon document={Icons.FILE_COPY_LINE} class="size-5"/>
		</div>;
		if (shown)
			ashui.css.Identity.of(item.tree, item.node.id).setAttribute("data-on", "");
		return <tooltip label="Explorer" side="right">{item}</tooltip>;
	}

	function explorer(shown:Bool):Element {
		if (!shown)
			return <div/>;
		return <div id="rayde-files" class="rayde-card panel flex flex-col flex-1 min-h-0">
			<div class="flex items-center px-4 shrink-0" height={36}><text class="rayde-heading">Explorer</text></div>
			<div class="flex flex-col flex-1 min-h-0 overflow-auto px-2 pb-2">
				<tree-view id="rayde-tree" selected={active} onSelect={v -> if (v.endsWith(".hx")) openFile(v)}>
					<tree-item value={props.display.cwd} label={props.name} icon={Icons.FOLDER_OPEN_LINE} expanded={true}>{folders()}</tree-item>
				</tree-view>
			</div>
		</div>;
	}

	/** The project's source folders, from the classpaths its build names. */
	function folders():Array<Element> {
		var args = props.display.args, out:Array<Element> = [];
		for (i in 0...args.length - 1)
			if (args[i] == "-cp" || args[i] == "--class-path") {
				var dir = haxe.io.Path.isAbsolute(args[i + 1]) ? args[i + 1] : haxe.io.Path.join([props.display.cwd, args[i + 1]]);
				if (sys.FileSystem.exists(dir) && sys.FileSystem.isDirectory(dir))
					out.push(folder(dir, args[i + 1], true));
			}
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
		return <tree-item value={dir} label={label} icon={Icons.FOLDER_LINE} expanded={expanded}>{children}</tree-item>;
	}

	/** The open files' tabs, the path to the file in front, and its editor. */
	function editorCard():Element
		return <div id="rayde-editor-card" class="rayde-card flex flex-col flex-1 min-h-0">
			<file-tabs files={open} active={active} dirty={dirty} onClose={closeFile}/>
			<for {files in [open.get()]}>${editors(files)}</for>
		</div>;

	function editors(files:Array<String>):Element {
		if (files.length == 0)
			return <div class="flex flex-col flex-1 items-center justify-center gap-3">
				<icon document={Icons.BRACES_LINE} class="size-8 text-text-tertiary"/>
				<text class="text-sm text-text-tertiary">Open a file from the Explorer to start editing.</text>
			</div>;
		return <div class="flex flex-col flex-1 min-h-0">
			<for {file in [active.get()]}>${breadcrumb(file)}</for>
			<tabs id="rayde-tabs" value={active} class="flex-1 min-h-0">
				<tabs-list indicator={false} class="rayde-nolist"/>
				{[for (f in files) page(f)]}
			</tabs>
		</div>;
	}

	/** Where `file` sits in the project, folder by folder. */
	function breadcrumb(file:String):Element {
		var root = haxe.io.Path.addTrailingSlash(props.display.cwd);
		var parts = (file.startsWith(root) ? file.substr(root.length) : file).split("/");
		return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs(parts)}</breadcrumb>;
	}

	function crumbs(parts:Array<String>):Array<Element>
		return [for (i => part in parts) <breadcrumb-item current={i == parts.length - 1}>${part}</breadcrumb-item>];

	/** One open file's editor, which checks the file as it is typed. */
	function page(file:String):Element
		return <tabs-content value={file} class="flex-1 min-h-0">
			<code-editor id={"rayde-editor-" + haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(file))} value={buffer(file)} language="haxe"
				lineNumbers={true} folding={true} indentGuides={true} highlightBrackets={true} tabSize={4} insertSpaces={false} onInput={_ -> edited(file)}
				class="flex-1 min-h-0"/>
		</tabs-content>;

	/** Problems and the Output of a run, as VS Code's panel names them. */
	function bottomCard():Element
		return <div id="rayde-panel" class="rayde-card panel flex flex-col flex-1 min-h-0">
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
		</div>;

	function problemsPane(list:Array<Diagnostic>):Element
		return <div id="rayde-problems" class="flex flex-col flex-1 min-h-0 overflow-auto">
			<if {list.length == 0}><div class="px-2 py-1"><text class="text-xs text-text-tertiary">No problems in the open files.</text></div></if>
			{[for (p in list) problemRow(p)]}
		</div>;

	function problemRow(p:Diagnostic):Element
		return <div class="rayde-problem flex items-center gap-2 px-2 py-1 cursor-pointer" onClick={_ -> openFile(p.file)}>
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
			<for {state in [runState.get()]}>${runStatus(state)}</for>
			<div class="rayde-status-item flex"><text>Haxe</text></div>
		</div>;

	function problemCounts(list:Array<Diagnostic>):Element {
		var errors = Lambda.count(list, p -> p.severity == 1), warnings = Lambda.count(list, p -> p.severity == 2);
		return <tooltip label="Problems in the open files" side="top">
			<div id="rayde-problem-counts" class="rayde-status-item action flex" onClick={_ -> bottom.set("problems")}>
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
