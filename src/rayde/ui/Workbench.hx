package rayde.ui;

import ashui.components.Badge;
import ashui.components.Button;
import ashui.components.CodeEditor;
import ashui.components.CodeView;
import ashui.components.Resizable;
import ashui.components.Tabs;
import ashui.components.TreeView;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.lang.Display;
import rayde.run.Runner;

using StringTools;

typedef WorkbenchProps = {
	display:Display,
	/** What the top bar names the project. */
	name:String,
	/** The runtime the project runs on, as its profile names it: ash or rayzor. */
	?runtime:String
};

/**
 * The IDE: the project's source tree, its open files in tabs over the code
 * editor, and below them the problems the compiler finds as they are edited and
 * the console of a run, each part resizable. What is open, and each buffer as
 * edited, lives here, so the panes can be rebuilt without losing either.
 * `run` keeps its own watch on a build or run; a host that drives the clock
 * itself can call `tick`.
 */
class Workbench extends Component<WorkbenchProps> {
	public final open = Signal.make(([] : Array<String>));
	public final active = Signal.make("");
	public final problems = Signal.make(([] : Array<Diagnostic>));
	final buffers = new Map<String, Signal<String>>();
	final edited = new Map<String, Bool>();
	final treeWidth = Signal.make(240.);
	final problemsHeight = Signal.make(190.);

	/** The tab shown below the editor: problems or console. */
	public final bottom = Signal.make("problems");

	/** What the build and the program have printed, and where the run is: idle, building, running, finished or failed. */
	final consoleText = Signal.make("");

	final runState = Signal.make("idle");
	public var runner(default, null):Null<Runner>;
	var seen = -1;
	var lastBuild:Null<Array<Diagnostic>>;

	/** Opens `file` in a tab, or brings its tab forward, and checks it. */
	public function openFile(file:String):Void {
		if (open.get().indexOf(file) < 0)
			open.set(open.get().concat([file]));
		active.set(file);
		check(file);
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

	/** Writes every edited buffer to its file: a build reads the files, so it should see them as they are in the editor. */
	public function saveAll():Void
		for (file => on in edited)
			if (on) {
				sys.io.File.saveContent(file, buffer(file).get());
				edited.set(file, false);
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

	function render():Element {
		runner = new Runner(props.display);
		return <div id="rayde" widthPercent={1} heightPercent={1} class="flex flex-col bg-background text-text-primary">
			<div id="rayde-bar" class="flex items-center gap-3 px-4 shrink-0" height={44}>
				<text class="text-sm font-medium">${props.name}</text>
				<badge variant={Secondary}>${props.runtime == null ? "ash" : props.runtime}</badge>
				<div class="flex-1"/>
				<for {state in [runState.get()]}>${runControls(state)}</for>
			</div>
			<div class="flex flex-1 min-h-0 px-3 pb-3">
				<resizable id="rayde-rows" direction="vertical" class="flex-1 min-h-0">
					<resizable-panel minSize={160}>
						<resizable id="rayde-columns" class="flex-1 min-h-0">
							<resizable-panel size={treeWidth} minSize={160} maxSize={480}>
								<div id="rayde-files" class="flex flex-col flex-1 min-h-0 overflow-auto p-2">
									<text class="text-xs text-text-tertiary px-2 pb-1">Files</text>
									<tree-view id="rayde-tree" selected={active} onSelect={v -> if (v.endsWith(".hx")) openFile(v)}>{folders()}</tree-view>
								</div>
							</resizable-panel>
							<resizable-panel minSize={320}>
								<for {k in [{files: open.get(), shown: active.get()}]}>${editors(k.files)}</for>
							</resizable-panel>
						</resizable>
					</resizable-panel>
					<resizable-panel size={problemsHeight} minSize={96} maxSize={480}>
						<tabs id="rayde-bottom" value={bottom} size={Sm} class="flex-1 min-h-0 p-2">
							<tabs-list class="shrink-0">
								<tabs-trigger id="rayde-tab-problems" value="problems">Problems</tabs-trigger>
								<tabs-trigger id="rayde-tab-console" value="console">Console</tabs-trigger>
							</tabs-list>
							<tabs-content value="problems" class="flex-1 min-h-0 pt-2"><for {list in [problems.get()]}>${problemsPane(list)}</for></tabs-content>
							<tabs-content value="console" class="flex-1 min-h-0 pt-2">
								<code-view id="rayde-console" value={consoleText} language="plain" lineNumbers={false} class="flex-1 min-h-0"/>
							</tabs-content>
						</tabs>
					</resizable-panel>
				</resizable>
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
				children.push(<tree-item value={path} label={name}/>);
		}
		return <tree-item value={dir} label={label} expanded={expanded}>{children}</tree-item>;
	}

	function editors(files:Array<String>):Element {
		if (files.length == 0)
			return <div class="flex flex-1 items-center justify-center"><text class="text-sm text-text-tertiary">Choose a file to open it.</text></div>;
		return <tabs id="rayde-tabs" value={active} size={Sm} class="flex-1 min-h-0 p-2">
			<tabs-list class="shrink-0">{[for (f in files) <tabs-trigger value={f}>${haxe.io.Path.withoutDirectory(f)}</tabs-trigger>]}</tabs-list>
			{[for (f in files) page(f)]}
		</tabs>;
	}

	/** One open file's tab: its editor, which checks the file as it is typed. */
	function page(file:String):Element
		return <tabs-content value={file} class="flex-1 min-h-0 pt-2">
			<code-editor id={"rayde-editor-" + haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(file))} value={buffer(file)} language="haxe"
				lineNumbers={true} folding={true} indentGuides={true} highlightBrackets={true} tabSize={4} insertSpaces={false} onInput={_ -> { edited.set(file, true); check(file); }}
				class="flex-1 min-h-0"/>
		</tabs-content>;

	function problemsPane(list:Array<Diagnostic>):Element {
		var errors = Lambda.count(list, p -> p.severity == 1), warnings = Lambda.count(list, p -> p.severity == 2);
		return <div id="rayde-problems" class="flex flex-col flex-1 min-h-0 gap-1">
			<div class="flex items-center gap-2 px-2 shrink-0">
				<if {errors > 0}><badge variant={Destructive}>${errors + (errors == 1 ? " error" : " errors")}</badge></if>
				<if {warnings > 0}><badge variant={Secondary}>${warnings + (warnings == 1 ? " warning" : " warnings")}</badge></if>
			</div>
			<div class="flex flex-col flex-1 min-h-0 overflow-auto">
				<if {list.length == 0}><text class="text-xs text-text-tertiary px-2 py-1">No problems in the open files.</text></if>
				{[for (p in list) problemRow(p)]}
			</div>
		</div>;
	}

	/** The Run button, or Stop while a build or run is going, and where the run stands. */
	function runControls(state:String):Element {
		var active = state == "building" || state == "running";
		return <div class="flex items-center gap-3">
			<if {state == "building"}><text class="text-xs text-text-tertiary">Building</text></if>
			<if {state == "running"}><text class="text-xs text-text-tertiary">Running</text></if>
			<if {state == "finished"}><text id="rayde-status" class="text-xs text-text-tertiary">${"Exited " + runner.exitCode}</text></if>
			<if {state == "failed"}><text id="rayde-status" class="text-xs text-error">Build failed</text></if>
			<if {active}><button id="rayde-stop" variant={Destructive} size={Sm} onClick={_ -> stopRun()}>Stop</button>
			<else><button id="rayde-run" variant={Outline} size={Sm} onClick={_ -> run()}>Run</button></if>
		</div>;
	}

	function problemRow(p:Diagnostic):Element
		return <div class="rayde-problem flex items-center gap-3 px-2 py-1">
			<if {p.severity == 1}><text class="text-xs text-error">Error</text>
			<else><text class="text-xs text-warning">${p.severity == 2 ? "Warning" : "Note"}</text></if>
			<text class="text-xs flex-1 min-w-0">${p.message.split("\n")[0]}</text>
			<text class="text-xs text-text-tertiary">${haxe.io.Path.withoutDirectory(p.file) + ":" + (p.range.start.line + 1)}</text>
		</div>;
}
