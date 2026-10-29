package rayde.ui.workbench;

import rayde.workspace.Fs;
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
import ashui.components.Spinner;
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
	public var appPreview(default, null):Null<rayde.run.AppPreviewBuild>;
	final previewRevision = Signal.make(0);

	function previewBuilding():Bool {
		previewRevision.get();
		return appPreview!=null && appPreview.state.get()=="building";
	}

	function statusState():String {
		previewRevision.get();
		var state=runState.get();
		if(appPreview!=null && (appPreview.state.get()=="building" || wb.active.get()==Workbench.APP_PREVIEW))
			return "preview-"+appPreview.state.get();
		return state;
	}

	function publishBuildOutput(text:String):Void {
		wb.extensionsPart.outputJobs.request("build", [text], null);
		if (!wb.extensionsPart.outputScheduled) { wb.extensionsPart.outputScheduled = true; ashui.animation.AnimationScheduler.main.after(.016, wb.extensionsPart.pollOutput); }
	}

	public function canPreviewApp():Bool {
		wb.buildRevision.get();runnerRevision.get();
		var session=rayde.workspace.PageHost.session;
        var kind=rayde.run.RunPlan.target(wb.props.display.args).kind;
        var rayzor=wb.props.display.project!=null && wb.props.display.project.runtime=="rayzor";
        return session!=null && (kind=="hl"&&!rayzor ? session.appPreviews : session.webPreviews) && wb.extension==null &&
            (rayzor&&wb.props.display.project.runnable || kind=="js" || runner!=null&&runner.configuration.mode=="browser" || kind=="hl"&&(wb.props.display.args.indexOf("-main")>=0||wb.props.display.args.indexOf("--main")>=0));
	}

	public function previewApp():Void {
		previewAppBuild(false);
	}
	public function forcePreviewApp():Void {
		previewAppBuild(true);
	}
	function previewAppBuild(force:Bool):Void {
		if(!canPreviewApp()){wb.say("Choose a browser-compatible Run Configuration and enable preview tooling on the workspace session.");return;}
		if(runner!=null && runner.active())return;
		saveBefore(() -> {
			if(appPreview==null){appPreview=new rayde.run.AppPreviewBuild(rayde.workspace.PageHost.session,publishBuildOutput);previewRevision.set(previewRevision.get()+1);}
			appPreview.start(wb.props.display.server.haxe,wb.props.display.args,wb.props.display.cwd,force,wb.props.display.project!=null&&wb.props.display.project.runtime=="rayzor" ? "rayzor" : "haxe",wb.props.display.project==null ? wb.props.display.hxml : wb.props.display.project.file);
			wb.openFile(Workbench.APP_PREVIEW);
		});
	}

	public function closeAppPreview():Void {
		if(appPreview!=null)appPreview.dispose();appPreview=null;
		previewRevision.set(previewRevision.get()+1);
	}

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
	public function saveAll():Void saveFiles(wb.dirty.get().copy());
	public function saveBefore(after:Void->Void):Void saveFiles(wb.dirty.get().copy(),after);
	var saving = false;

	function saveFiles(files:Array<String>, ?after:Void->Void):Void {
		if (saving) { wb.say("Saving changes…"); return; }
		saving = true;
		function next():Void {
			if (wb.gone) { saving = false; return; }
			var file = files.shift();
			if (file == null) {
				saving = false;
				if (after != null) {
					if (wb.dirty.get().length > 0) wb.say("Files changed while saving. Save again before continuing.");
					else try after() catch (error:Dynamic) wb.say(Std.string(error));
				}
				return;
			}
			try {
				if (wb.documentsPart.sessionDocs != null && wb.documentsPart.sessionDocs.save(file, (error, text) -> {
					if (wb.gone) return;
					if (error != null) { saving = false; wb.say(haxe.io.Path.withoutDirectory(file) + ": " + error); return; }
					try { fileSaved(file,text); next(); } catch (failure:Dynamic) { saving = false; wb.say(Std.string(failure)); }
				})) return;
				var text = wb.documentsPart.buffer(file).get();
				Fs.saveContent(file,text); fileSaved(file,text); next();
			} catch (error:Dynamic) { saving = false; wb.say(Std.string(error)); }
		}
		next();
	}

	/** Saves one tab without writing other dirty buffers. */
	public function saveFile(file:String):Void {
		if (Workbench.isVirtual(file) || wb.dirty.get().indexOf(file) < 0 || wb.contributions.readOnly(file)) return;
		saveFiles([file]);
	}

	function fileSaved(file:String, text:String):Void {
		var current = wb.documentsPart.buffer(file).get();
		if (current == text) {
			wb.documentsPart.localHistory.saved(file, text, wb.documentsPart.documents.exists(file) ? DocumentHistory.snapshot(wb.documentsPart.documents.get(file)) : null);
		}
		var studio = wb.extensionsPart.studios.get(file);
		if (studio != null && !studio.live.get()) studio.reload();
		wb.emit("file.saved", {path:file});
		var client = wb.languagesPart.languageServers.client(file);
		if (client != null) { wb.languagesPart.languageServers.sync(file,wb.documentsPart.buffer(file).get()); client.saved(file); }
		if (current == text) wb.dirty.set(wb.dirty.get().filter(path -> path != file));
	}

	/** Saves what is edited, then builds the project and runs it. */
	public function run():Void {
		if(previewBuilding() || runner.state=="building")return;
		if (wb.props.empty == true || !runner.canRun() && !ExtensionsPart.isExtension(wb.active.get())) return;
		// Run is Continue while the extension is stopped.
		var d = wb.debugPart.debugger();
		if (d != null && d.stopped.get() != null) {
			d.resume("continue");
			return;
		}
		saveBefore(runSaved);
	}

	function runSaved():Void {
		if(previewBuilding() || runner.state=="building")return;
		if (wb.extension != null || ExtensionsPart.isExtension(wb.active.get())) {
			(wb.extension != null ? wb.extensionsPart.extensionStudio() : wb.extensionsPart.studioOf(wb.active.get())).reload();
			wb.panelsPart.showPanel("extension");
			return;
		}
        #if (wasm || rayde_page)
        if(canPreviewApp() && runner.configuration.mode=="browser"){previewApp();return;}
        #end
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
		if (!canBuild() || runner.active() || previewBuilding()) return;
		saveBefore(() -> { runner.build(); wb.panelsPart.showPanel("console"); poll(); });
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
		if(previewBuilding())appPreview.stop();
		else if(runner!=null)runner.stop();
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
		publishBuildOutput(runner.console);
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

	/** Project actions stay in place while builds report progress and Stop is available. */
	function runControls(state:String):Element {
		var runnable = runner!=null && runner.canRun();
		if (wb.props.empty == true || !runnable && !canBuild()) return <div/>;
		var building = state == "preview-building" || state == "building", active = building || state == "running";
		var buildLabel = building ? (state == "preview-building" ? "Building app preview" : "Building project") : "Build project";
		var shortcut = wb.keymapPart.bindings.label("buildproject");
		var runShortcut = wb.keymapPart.bindings.label("run");
		var controls = <div id="rayde-run-controls" class="flex items-center gap-1" onPointerDown={e -> e.stopPropagation()}>
			<if {active}><tooltip label="Stop" side="bottom"><button id="rayde-stop" variant={Outline} size={Icon} class="rayde-toolbar-action text-error" onClick={_ -> stopRun()}><icon document={Icons.STOP_FILL} class="size-4"/></button></tooltip></if>
			<if {canBuild()}><tooltip label={buildLabel + (building || shortcut == null ? "" : " (" + shortcut + ")")} side="bottom">
				<button id="rayde-build-action" variant={Outline} size={Icon} class="rayde-toolbar-action" disabled={active} onClick={_ -> buildProject()}>
					<if {building}><spinner id="rayde-build-spinner" size={Sm}/><else><icon document={Icons.HAMMER_LINE} class="size-4"/></if>
				</button>
			</tooltip></if>
			<if {runnable}><tooltip label={"Run project" + (runShortcut == null ? "" : " (" + runShortcut + ")")} side="bottom"><button id="rayde-run" variant={Outline} size={Icon} class="rayde-toolbar-action" disabled={active} onClick={_ -> run()}><icon document={Icons.PLAY_FILL} class="size-4"/></button></tooltip></if>
		</div>;
		for (action in [{id:"rayde-build-action",label:buildLabel},{id:"rayde-run",label:"Run project"},{id:"rayde-stop",label:"Stop"}])
			for (node in ashui.css.Css.query(controls.tree,controls.node.id,"#" + action.id)) {
				var identity=ashui.css.Identity.of(controls.tree,node).setAttribute("aria-label",action.label);
				if(action.id=="rayde-build-action")identity.setAttribute("aria-busy",building ? "true" : "false");
			}
		return controls;
	}

	/** Build progress and results remain visible in the status bar. */
	function runStatus(state:String):Element {
		if (wb.props.empty == true) return <div/>;
		var preview = state == "preview-building";
		return <div class="flex items-center gap-2">
			<if {preview}><tooltip label="Building app preview · Click for Build output" side="top">
				<button id="rayde-preview-building" variant={Ghost} size={Sm} class="rayde-status-item action" onClick={_ -> wb.panelsPart.showPanel("console")}><spinner size={Sm}/><text>${appPreview.phase.get()+" · "+appPreview.elapsed.get()+"s"}</text></button>
			</tooltip><else><if {state == "building"}><div class="flex items-center gap-1.5"><spinner size={Sm}/><text class="text-text-secondary">Building</text></div></if></if>
			<if {state == "running"}><text class="text-text-tertiary">Running</text></if>
			<if {state == "finished"}><text id="rayde-status" class="text-text-tertiary">${"Exited " + runner.exitCode}</text></if>
			<if {state == "built"}><text id="rayde-status" class="text-text-tertiary">Build succeeded</text></if>
			<if {state == "failed"}><text id="rayde-status" class="text-error">Build failed</text></if>
			<if {state == "preview-ready"}><text class="text-success">Preview ready</text></if>
			<if {state == "preview-failed"}><button variant={Ghost} size={Sm} class="rayde-status-item text-error" onClick={_ -> wb.panelsPart.showPanel("console")}>Preview build failed</button></if>
			<if {state == "preview-cancelled"}><text class="text-text-secondary">Build cancelled</text></if>
		</div>;
	}
}
