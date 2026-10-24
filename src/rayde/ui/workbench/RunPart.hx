package rayde.ui.workbench;

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
import rayde.ui.*;
import rayde.ui.workbench.Types;

using StringTools;

/** Part of the workbench, split out of it: RunPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class RunPart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	final runnerRevision = Signal.make(0);

	/** What the build and the program have printed, and where the run is: idle, building, running, finished or failed. */
	final consoleText = Signal.make("");

	final runState = Signal.make("idle");

	var runPollScheduled = false;

	public var runner(default, null):Null<Runner>;

	var seen = -1;

	var lastBuild:Null<Array<Diagnostic>>;

	// Tasks

	/** The project's tasks as choices for the center, each run in a terminal of its own. */
	function taskChoices():Array<CenterAction> {
		var out:Array<CenterAction> = [];
		for (i => t in Tasks.list(wb.props.display))
			out.push({id: "task-" + i, label: t.label, icon: Icons.PLAY_FILL, shortcut: t.detail, run: () -> runTask(t)});
		return out;
	}

	/** Runs `task` in a new terminal, which stays after the command ends so its output can be read. */
	public function runTask(task:Task):Void {
		var windows = Sys.systemName() == "Windows";
		wb.terminalPart.starting = true;
		wb.panelsPart.showPanel("terminal");
		wb.terminalPart.starting = false;
		wb.terminalPart.startSession({name: task.label, program: windows ? "cmd.exe" : "/bin/sh", args: [windows ? "/c" : "-c", task.command]});
		wb.terminalPart.focusTerminal();
	}

	public function runTaskPicker():Void {
		var tasks = taskChoices();
		if (tasks.length == 0)
			wb.say("No tasks. Configure Tasks adds some");
		else
			wb.openPicker("Run a task", tasks);
	}

	/** Opens the project's tasks file, made with an example when there is none. */
	public function configureTasks():Void
		wb.openFile(Tasks.ensure(wb.props.display.cwd));

	/** Writes every edited buffer to its file: a build reads the files, so it should see them as they are in the editor. */
	public function saveAll():Void {
		for (file in wb.dirty.get()) {
			sys.io.File.saveContent(file, wb.documentsPart.buffer(file).get());
			wb.documentsPart.localHistory.saved(file, wb.documentsPart.buffer(file).get(), wb.documentsPart.documents.exists(file) ? DocumentHistory.snapshot(wb.documentsPart.documents.get(file)) : null);
			var studio = wb.extensionsPart.studios.get(file);
			if (studio != null && !studio.live.get())
				studio.reload();
			wb.emit("file.saved", {path: file});
			var client = wb.languagesPart.languageServers.client(file);
			if (client != null) { wb.languagesPart.languageServers.sync(file, wb.documentsPart.buffer(file).get()); client.saved(file); }
		}
		if (wb.dirty.get().length > 0)
			wb.dirty.set([]);
	}

	/** Saves what is edited, then builds the project and runs it. */
	public function run():Void {
		if (wb.props.empty == true || wb.props.display.project != null && !wb.props.display.project.runnable && !ExtensionsPart.isExtension(wb.active.get())) return;
		// Run is Continue while the extension is stopped.
		var d = wb.debugPart.debugger();
		if (d != null && d.stopped.get() != null) {
			d.resume("continue");
			return;
		}
		saveAll();
		if (wb.extension != null || ExtensionsPart.isExtension(wb.active.get())) {
			(wb.extension != null ? wb.extensionsPart.extensionStudio() : wb.extensionsPart.studioOf(wb.active.get())).reload();
			wb.panelsPart.showPanel("extension");
			return;
		}
		runner.start();
		wb.panelsPart.showPanel("console");
		poll();
	}

	function canBuild():Bool {
		wb.buildRevision.get();
		return wb.props.empty != true && runner != null && runner.canBuild();
	}

	/** Saves edited files and builds the project's declared targets on the process worker. */
	public function buildProject():Void {
		if (!canBuild() || runner.active()) return;
		saveAll();
		runner.build();
		wb.panelsPart.showPanel("console");
		poll();
	}

	/** While a build or run is going, looks at it ten times a second; a window that is otherwise still draws no frames to do it from. */
	function poll():Void {
		if (wb.gone) return;
		tick();
		if (runner.active() && !runPollScheduled) {
			runPollScheduled = true;
			ashui.animation.AnimationScheduler.main.after(.1, () -> { runPollScheduled = false; poll(); });
		}
	}

	public function stopRun():Void {
		runner.stop();
		tick();
	}

	/** Moves a build or run along and shows what it printed. */
	public function tick():Void {
		if (runner == null)
			return;
		runner.tick();
		if (runner.revision == seen)
			return;
		seen = runner.revision;
		wb.extensionsPart.outputJobs.request("build", [runner.console], null);
		if (!wb.extensionsPart.outputScheduled) { wb.extensionsPart.outputScheduled = true; ashui.animation.AnimationScheduler.main.after(.016, wb.extensionsPart.pollOutput); }
		runState.set(runner.state);
		if (runner.problems != lastBuild) {
			var previous = lastBuild;
			lastBuild = runner.problems;
			wb.problems.set([for (p in wb.problems.get()) if ((previous == null || previous.indexOf(p) < 0) && !Lambda.exists(runner.problems, b -> b.file == p.file)) p].concat(runner.problems));
			if (runner.state == "failed" && runner.problems.length > 0)
				wb.panelsPart.showPanel("problems");
		}
	}

	function buildLog():Element {
		wb.extensionsPart.buildOutputSyntax.spans = wb.extensionsPart.outputSpans.get("build");
		var view:CodeView = <code-view id="rayde-console" state={wb.extensionsPart.outputState("build")} highlighter={wb.extensionsPart.buildOutputSyntax} tokenStyles={true} lineNumbers={false} folding={false} class="rayde-output flex-1 min-h-0"/>;
		new ashui.reactive.Watch(() -> wb.extensionsPart.outputStyleRevision.get(), _ -> {
			var spans = wb.extensionsPart.outputSpans.get("build");
			if (wb.extensionsPart.buildOutputSyntax.spans == spans) return;
			wb.extensionsPart.buildOutputSyntax.spans = spans;
			view.metrics.syntax = new OutputHighlighter(null, spans);
			view.expandAll();
		});
		return view;
	}

	/** Build and Run share progress and Stop, with separate actions while idle. */
	function runStatus(state:String):Element {
		var runnable = wb.props.display.project == null || wb.props.display.project.runnable;
		if (wb.props.empty == true || !runnable && !canBuild()) return <div/>;
		var active = state == "building" || state == "running";
		var shortcut = wb.keymapPart.bindings.label("buildproject");
		return <div class="flex items-center gap-2">
			<if {canBuild()}><tooltip label={"Build project" + (shortcut == null ? "" : " (" + shortcut + ")")} side="top">
				<button id="rayde-build" variant={Ghost} size={Sm} class="rayde-status-item action" disabled={active} onClick={_ -> buildProject()}><icon document={Icons.HAMMER_LINE} class="size-3.5"/>Build</button>
			</tooltip></if>
			<if {state == "building"}><text class="text-text-tertiary">Building</text></if>
			<if {state == "running"}><text class="text-text-tertiary">Running</text></if>
			<if {state == "finished"}><text id="rayde-status" class="text-text-tertiary">${"Exited " + runner.exitCode}</text></if>
			<if {state == "built"}><text id="rayde-status" class="text-text-tertiary">Build succeeded</text></if>
			<if {state == "failed"}><text id="rayde-status" class="text-error">Build failed</text></if>
			<if {active}><div id="rayde-stop" class="rayde-status-item action flex text-error" onClick={_ -> stopRun()}><icon document={Icons.STOP_FILL} class="size-3.5"/><text>Stop</text></div>
			<else><if {runnable}><div id="rayde-run" class="rayde-status-item action flex" onClick={_ -> run()}><icon document={Icons.PLAY_FILL} class="size-3.5"/><text>Run</text></div></if></if>
		</div>;
	}
}
