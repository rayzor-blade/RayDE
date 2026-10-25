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

/** Part of the workbench, split out of it: ProjectPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class ProjectPart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	final projectPicker = new rayde.run.Worker<rayde.ui.ProjectPicker.ProjectPickRequest, Null<String>>(ProjectPicker.choose);

	var pickingProject = false;

	var cancelProjectDialog:Null<Void->Void>;

	final creatingProject = Signal.make(false);

	final projectStarters = new rayde.project.ProjectStarters();

	final starterRevision = Signal.make(0);

	public function openWorkspace(path:String):Void {
		if (wb.props.onNewWorkspace != null) {
			try wb.props.onNewWorkspace(path) catch (error:Dynamic) wb.say(Std.string(error));
			return;
		}
		if (wb.props.onWorkspace == null) { wb.say("Workspace opening requires an editor window"); return; }
		function open():Void wb.props.onWorkspace(path);
		if (wb.dirty.get().length > 0) {
			wb.prompt.set({title:"Open another workspace", description:"Save your edited files before switching workspaces.", action:"Save and Open",
				accept:_ -> { wb.runPart.saveAll(); open(); }});
		} else try open() catch (error:Dynamic) wb.say(Std.string(error));
	}

	/** Defers a window close while edited files need a save decision. */
	public function mayCloseWindow(close:Void->Void):Bool {
		if (wb.dirty.get().length == 0) return true;
		if (wb.prompt.get() == null) wb.prompt.set({title:"Close Window", description:"Save your edited files before closing this window.", action:"Save and Close",
			accept:_ -> { wb.runPart.saveAll(); if (wb.dirty.get().length > 0) throw "Some files could not be saved."; close(); },
			alternative:"Don't Save", discard:close});
		return false;
	}

	function pickProject(mode:String):Void {
		if (pickingProject) return;
		pickingProject = true;
		#if ashui_window
		var app = ashui.app.WindowedApp.current;
		if (app != null && ashui.app.FileDialog.available()) {
			try cancelProjectDialog = ashui.app.FileDialog.open(app, {
				title:mode == "folder" ? "Open Folder Workspace" : "Open Project",
				folder:mode != "project", directory:wb.props.display.cwd, extensions:["hxml", "json", "toml", "cbproj", "rayext", "raytheme"]
			}, selected -> {
				cancelProjectDialog = null;
				pickingProject = false;
				if (wb.gone || selected == null) return;
				openWorkspace(selected);
			}) catch (error:Dynamic) { pickingProject = false; wb.say(Std.string(error)); }
			return;
		}
		#end
		projectPicker.submit("pick", {mode:mode});
		ashui.animation.AnimationScheduler.main.after(.03, pollProjectPicker);
	}

	function pollProjectPicker():Void {
		if (wb.gone) return;
		for (result in projectPicker.poll()) {
			pickingProject = false;
			if (result.error != null) wb.say(result.error);
			else if (result.value != null) openWorkspace(result.value);
		}
		if (pickingProject) ashui.animation.AnimationScheduler.main.after(.05, pollProjectPicker);
	}

	function newProject():Void {
		wb.quickOpen.set(false);
		creatingProject.set(true);
		ashui.animation.AnimationScheduler.main.after(.016, () -> {
			if (wb.gone) return;
			wb.extensionsPart.discoverExtensions(false);
			wb.extensionsPart.extensionManager.newProject();
		});
	}

	function projectTemplates():Array<rayde.project.ProjectTemplates.ProjectTemplate> {
		starterRevision.get();
		return rayde.project.ProjectTemplates.all.concat(projectStarters.list());
	}

	function recentProjects():Void {
		wb.openPicker("Open a recent project or folder", [for (path in rayde.settings.RecentProjects.paths()) {
			id:path, label:haxe.io.Path.withoutDirectory(path), shortcut:haxe.io.Path.directory(path), icon:Icons.FOLDER_OPEN_LINE, run:() -> openWorkspace(path)
		}]);
	}
}
