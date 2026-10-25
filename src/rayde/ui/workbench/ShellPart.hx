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

/** Part of the workbench, split out of it: ShellPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class ShellPart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	/** The commands: what the center lists after `>`, what the Settings page lets a key be chosen for, and what a key runs. */
	function coreCommands():Array<CenterAction>
		return [
			{id:"newwindow", label:"New Window", icon:Icons.WINDOW_LINE, run:() -> if (wb.props.onNewWindow != null) wb.props.onNewWindow()},
			{id:"closewindow", label:"Close Window", icon:Icons.CLOSE_LINE, run:() -> wb.chrome.close()},
			{id:"openfolder", label:"Open Folder…", icon:Icons.FOLDER_OPEN_LINE, run:() -> wb.projectPart.pickProject("folder")},
			{id:"openproject", label:"Open Project…", icon:Icons.FILE_CODE_LINE, run:() -> wb.projectPart.pickProject("project")},
			{id:"newproject", label:"New Project…", icon:Icons.FOLDER_ADD_LINE, run:wb.projectPart.newProject},
			{id:"recentprojects", label:"Open Recent Workspace…", icon:Icons.HISTORY_LINE, run:wb.projectPart.recentProjects},
			{id: "quickopen", label: "Go to File...", icon: Icons.SEARCH_LINE, run: () -> wb.openCenter()},
			{id: "commands", label: "Show All Commands", icon: Icons.CODE_BOX_LINE, run: () -> wb.openCenter(">")},
			{id: "gotoline", label: "Go to Line...", icon: Icons.ARROW_RIGHT_LINE, run: () -> wb.openCenter(":")},
			{id: "find", label: "Find", icon: Icons.SEARCH_LINE, run: () -> wb.editorFind()},
			{id: "replace", label: "Replace", icon: Icons.FIND_REPLACE_LINE, run: () -> wb.editorFind(true)},
			{id: "findnext", label: "Find Next", icon: Icons.ARROW_DOWN_LINE, run: () -> wb.editorFindNext()},
			{id: "findprevious", label: "Find Previous", icon: Icons.ARROW_UP_LINE, run: () -> wb.editorFindNext(true)},
			{id: "run", label: "Run", icon: Icons.PLAY_FILL, run: wb.runPart.run},
			{id: "buildproject", label: "Build Project", icon: Icons.HAMMER_LINE, run: wb.runPart.buildProject},
			{id: "stop", label: "Stop", icon: Icons.STOP_FILL, run: wb.runPart.stopRun},
			{id: "save", label: "Save All", icon: Icons.SAVE_3_LINE, run: wb.runPart.saveAll},
			{id: "close", label: "Close Tab", icon: Icons.CLOSE_LINE, run: () -> if (wb.active.get() != "") wb.closeFile(wb.active.get())},
			{id:"filehistorydiff", label:"File: Open History Diff", icon:Icons.FILE_HISTORY_LINE, run:() -> wb.documentsPart.openComparison()},
			{id:"splitright", label:"Split Editor Right (Vertical)", icon:Icons.LAYOUT_COLUMN_LINE, run:() -> wb.editorPart.splitEditor("horizontal")},
			{id:"splitdown", label:"Split Editor Down (Horizontal)", icon:Icons.LAYOUT_ROW_LINE, run:() -> wb.editorPart.splitEditor("vertical")},
			{id:"focusnextgroup", label:"Focus Next Editor Group", icon:Icons.ARROW_RIGHT_LINE, run:() -> wb.editorPart.focusGroup()},
			{id:"focuspreviousgroup", label:"Focus Previous Editor Group", icon:Icons.ARROW_LEFT_LINE, run:() -> wb.editorPart.focusGroup(true)},
			{id:"moveeditorgroup", label:"Move Editor to Next Group", icon:Icons.ARROW_RIGHT_LINE, run:wb.editorPart.moveEditor},
			{id:"joingroups", label:"Join All Editor Groups", icon:Icons.LAYOUT_LINE, run:wb.editorPart.joinGroups},
			{id:"closeeditorgroup", label:"Close Editor Group", icon:Icons.CLOSE_LINE, run:wb.editorPart.closeGroup},
			{id: "definition", label: "Go to Definition", icon: Icons.CORNER_DOWN_RIGHT_LINE, run: wb.goToDefinition},
			{id:"typedefinition",label:"Go to Type Definition",icon:Icons.CORNER_DOWN_RIGHT_LINE,run:() -> EditorCommands.active(wb,"typedefinition")},
			{id:"implementation",label:"Go to Implementations",icon:Icons.CORNER_DOWN_RIGHT_LINE,run:() -> EditorCommands.active(wb,"implementation")},
			{id:"references",label:"Find All References",icon:Icons.SEARCH_LINE,run:() -> EditorCommands.active(wb,"references")},
			{id:"renamesymbol",label:"Rename Symbol",icon:Icons.EDIT_LINE,run:() -> EditorCommands.active(wb,"renamesymbol")},
			{id:"formatdocument",label:"Format Document",icon:Icons.CODE_LINE,run:() -> EditorCommands.active(wb,"formatdocument")},
			{id: "suggest", label: "Trigger Suggest", icon: Icons.LIGHTBULB_LINE, run: wb.triggerSuggest},
			{id:"codeactions", label:"Show Code Actions", icon:Icons.LIGHTBULB_LINE, run:wb.codeActionsPart.showCodeActions},
			{id: "parameterhints", label: "Trigger Parameter Hints", icon: Icons.BRACES_LINE, run: wb.triggerParameterHints},
			{id: "settings", label: "Open Settings", icon: Icons.SETTINGS_3_LINE, run: () -> wb.openSettings()},
			{id: "build", label: "Open Build Settings", icon: Icons.SETTINGS_3_LINE, run: wb.openBuild},
			{id: "libraries", label: "Manage Libraries", icon: Icons.BOOK_2_LINE, run: () -> wb.openSettings("libraries")},
			{id: "colorscheme", label: "Color Scheme", icon: Icons.PALETTE_LINE, run: () -> wb.openSettings("appearance")},
			{id: "keybindings", label: "Open Keyboard Shortcuts", icon: Icons.KEYBOARD_LINE, run: () -> wb.openSettings("keys")},
			{id: "keymap", label: "Select Keymap...", icon: Icons.KEYBOARD_LINE, run: wb.keymapPart.selectKeymap},
			{id: "extensions", label: "Show Extensions", icon: Icons.PUZZLE_LINE, run: () -> wb.openSettings("extensions")},
			{id: "problems", label: "Show Problems", icon: Icons.CLOSE_CIRCLE_LINE, run: () -> wb.panelsPart.showPanel("problems")},
			{id: "output", label: "Show Output", icon: Icons.TERMINAL_BOX_LINE, run: () -> wb.panelsPart.showPanel("console")},
			{id: "extension", label: "Show Extension Console", icon: Icons.PUZZLE_LINE, run: () -> wb.panelsPart.showPanel("extension")},
			{id: "newfile", label: "New File…", icon: Icons.FILE_ADD_LINE, run: () -> wb.explorerPart.askCreate(wb.explorerPart.selectedFolder(), false)},
			{id: "newfolder", label: "New Folder…", icon: Icons.FOLDER_ADD_LINE, run: () -> wb.explorerPart.askCreate(wb.explorerPart.selectedFolder(), true)},
			{id: "filerename", label: "Rename File…", icon: Icons.EDIT_LINE, run: () -> wb.explorerPart.withSelected(wb.explorerPart.askRename)},
			{id: "filedelete", label: "Delete File…", icon: Icons.DELETE_BIN_LINE, run: () -> wb.explorerPart.withSelected(wb.explorerPart.askDelete)},
			{id: "filecopy", label: "Copy File", icon: Icons.FILE_COPY_LINE, run: () -> wb.explorerPart.withSelected(p -> wb.explorerPart.copyFile(p, false))},
			{id: "filecut", label: "Cut File", icon: Icons.SCISSORS_LINE, run: () -> wb.explorerPart.withSelected(p -> wb.explorerPart.copyFile(p, true))},
			{id: "filepaste", label: "Paste File", icon: Icons.CLIPBOARD_LINE, run: () -> wb.explorerPart.pasteFiles(wb.explorerPart.selectedFolder())},
			{id: "fileduplicate", label: "Duplicate File", icon: Icons.FILE_COPY_2_LINE, run: () -> wb.explorerPart.withSelected(wb.explorerPart.duplicateFile)},
			{id: "filecopypath", label: "Copy File Path", icon: Icons.LINK_M, run: () -> wb.explorerPart.withSelected(p -> ashui.input.Clipboard.setText(p))},
			{id: "filecopyrelative", label: "Copy Relative File Path", icon: Icons.LINK_M, run: () -> wb.explorerPart.withSelected(p -> ashui.input.Clipboard.setText(FileOps.relative(wb.props.display.cwd, p)))},
			{id: "filereveal", label: rayde.Platform.isMac() ? "Reveal File in Finder" : "Reveal File in File Manager", icon: Icons.FOLDER_OPEN_LINE, run: () -> wb.explorerPart.withSelected(FileOps.reveal)},
			{id: "minimize", label: "Minimize Window", icon: Icons.SUBTRACT_LINE, run: () -> wb.chrome.minimize()},
			{id: "fullscreen", label: "Toggle Full Screen", icon: Icons.FULLSCREEN_LINE, run: () -> wb.chrome.toggleFullscreen()},
			{id: "maximize", label: "Toggle Maximize Window", icon: Icons.CHECKBOX_BLANK_LINE, run: () -> wb.chrome.toggleMaximize()},
			{id: "togglebreakpoint", label: "Toggle Breakpoint", icon: Icons.CIRCLE_FILL, run: wb.debugPart.toggleBreakpoint},
			{id: "continue", label: "Continue", icon: Icons.PLAY_FILL, run: () -> wb.debugPart.debugResume("continue")},
			{id: "pause", label: "Pause Extension", icon: Icons.PAUSE_FILL, run: () -> {
				var d = wb.debugPart.debugger();
				if (d != null)
					d.pause();
			}},
			{id: "stepover", label: "Step Over", icon: Icons.ARROW_GO_FORWARD_LINE, run: () -> wb.debugPart.debugResume("stepOver")},
			{id: "stepinto", label: "Step Into", icon: Icons.CORNER_RIGHT_DOWN_LINE, run: () -> wb.debugPart.debugResume("stepIn")},
			{id: "stepout", label: "Step Out", icon: Icons.CORNER_UP_RIGHT_LINE, run: () -> wb.debugPart.debugResume("stepOut")},
			{id: "clearbreakpoints", label: "Remove All Breakpoints", icon: Icons.DELETE_BIN_LINE, run: () -> {
				var d = wb.debugPart.debugger();
				if (d != null)
					d.clear();
			}},
			{id: "extensionreload", label: "Reload Extension", icon: Icons.REFRESH_LINE, run: () -> if (wb.extension != null) wb.extensionsPart.extensionStudio().reload() else if (ExtensionsPart.isExtension(wb.active.get())) wb.extensionsPart.studioOf(wb.active.get()).reload()},
			{id: "terminal", label: "Open Terminal", icon: Icons.TERMINAL_BOX_LINE, run: wb.terminalPart.toggleTerminal},
			{id: "newterminal", label: "New Terminal", icon: Icons.ADD_LINE, run: () -> wb.terminalPart.newTerminal()},
			{id: "splitterminal", label: "Split Terminal", icon: Icons.LAYOUT_COLUMN_LINE, run: () -> wb.terminalPart.splitTerminal()},
			{id: "terminalprofile", label: "Select Default Terminal Profile", icon: Icons.TERMINAL_BOX_LINE, run: wb.terminalPart.selectDefaultProfile},
			{id: "terminalsettings", label: "Configure Terminal Settings", icon: Icons.SETTINGS_3_LINE, run: wb.terminalPart.openTerminalSettings},
			{id: "runtask", label: "Run Task", icon: Icons.PLAY_FILL, run: wb.runPart.runTaskPicker},
			{id: "configuretasks", label: "Configure Tasks", icon: Icons.CODE_BOX_LINE, run: wb.runPart.configureTasks},
			{id: "panel", label: "Toggle Panel", icon: Icons.LAYOUT_BOTTOM_LINE, run: wb.panelsPart.togglePanel},
			{id: "explorer", label: "Toggle Explorer", icon: Icons.FOLDERS_LINE, run: wb.explorerPart.toggleExplorer}
		];

	/** The commands as registered, which in an empty window are only those that do not need a project. */
	function commands():Array<CenterAction> {
		var all = wb.contributions.commands();
		return wb.props.empty != true ? all : all.filter(action -> ["newwindow", "closewindow", "openfolder", "openproject", "newproject", "recentprojects", "commands", "settings", "colorscheme", "keybindings", "keymap", "minimize", "fullscreen", "maximize", "explorer"].indexOf(action.id) >= 0);
	}

	/** What the workbench itself puts in the bars and the command center, and then what each built-in feature does. */
	function registerShell():Void {
		for (command in coreCommands()) wb.contributions.command(command);
		wb.contributions.commandSource(wb.extensionsPart.contributedCommands);
		wb.contributions.activity({id:"rayde-activity-explorer", title:"Explorer", icon:Icons.FOLDERS_LINE, order:0,
			on:() -> wb.explorerShown.get() && wb.sideView.get() == "explorer", run:wb.explorerPart.chooseExplorer});
		wb.contributions.activitySource(() -> {
			var out:Array<ActivityEntry> = [];
			for (c in wb.extensionsPart.containers) if (c.location != "explorer") {
				var container = c;
				out.push({id:"rayde-activity-" + c.id, title:c.title, icon:c.icon, order:200,
					// Only the view the side panel shows is selected; a view in another part of the layout is toggled from here but is not what the bar is showing.
					on:() -> container.location == "sidebar" && wb.explorerShown.get() && wb.sideView.get() == container.id, run:() -> chooseContainer(container)});
			}
			return out;
		});
		wb.contributions.activity({id:"rayde-activity-settings", title:"Settings", icon:Icons.SETTINGS_3_LINE, place:"bottom", order:0,
			on:() -> wb.active.get() == Workbench.SETTINGS, run:() -> wb.openSettings()});
		wb.contributions.status({id:"problems", place:"left", order:300, build:() -> <for {list in [wb.problems.get()]}>${wb.panelsPart.problemCounts(list)}</for>});
		wb.contributions.status({id:"notice", place:"right", order:100, build:() -> <if {wb.notice.get() != ""}><text id="rayde-notice">${wb.notice}</text></if>});
		wb.contributions.status({id:"run", place:"right", order:200, build:() -> <for {state in [wb.runPart.runState.get()]}>${wb.runPart.runStatus(state)}</for>});
		wb.contributions.status({id:"language-server", place:"right", order:400, build:() -> <for {server in [wb.languagesPart.languageStatus()]}><if {server != null}>${wb.languagesPart.languageServerItem(server)}</if></for>});
		wb.contributions.status({id:"language", place:"right", order:500, build:() ->
			<for {name in [LanguageNames.of(wb.realFile(wb.active.get()))]}><if {name != null}><div id="rayde-language" class="rayde-status-item flex"><text>${name}</text></div></if></for>});
		wb.contributions.status({id:"runtime", place:"right", order:600, build:() -> <if {wb.runtime() != ""}><tooltip label={"This project runs on the " + wb.runtime() + " runtime"} side="top">
			<div id="rayde-runtime" class="rayde-status-item flex"><icon document={Icons.TERMINAL_BOX_LINE} class="size-3.5"/><text>${wb.runtime() + " runtime"}</text></div>
		</tooltip></if>});
		wb.contributions.status({id:"panel", place:"right", order:700, build:() -> <for {on in [wb.panelsPart.panelShown.get()]}>${wb.panelItem(on)}</for>});
		if (wb.props.empty != true) Features.installAll(host());
	}

	/** The surface the built-in features are given of this workbench. */
	function host():Host
		return {
			contributions: wb.contributions, cwd: wb.props.display.cwd, name: wb.props.name ?? haxe.io.Path.withoutDirectory(wb.props.display.cwd),
			active: wb.active, dirty: wb.dirty, closed: () -> wb.gone,
			isDocument: file -> file != "" && !Workbench.isVirtual(file) && !ImagePreview.isRaster(file) && FileOps.inside(wb.props.display.cwd, file),
			hasBuffer: file -> wb.documentsPart.buffers.exists(file), state: wb.documentsPart.documentState, editorOf: wb.editorOf, open: wb.openFile, say: wb.say, ask: request -> wb.prompt.set(request),
			edited: wb.documentsPart.edited, releaseDocuments: wb.documentsPart.releaseClosedDocuments,
			showSidebar: id -> { wb.sideView.set(id); if (!wb.explorerShown.get()) wb.treeWidth.set(Workbench.ACTIVITY + Workbench.EXPLORER_WIDTH); },
			hideSidebar: () -> wb.treeWidth.set(Workbench.ACTIVITY),
			sidebarShown: id -> wb.explorerShown.get() && wb.sideView.get() == id
		};

	/** The side panel, the editor with the bottom panel under it, and the right side bar when an extension view is there. */
	function columns():Element {
		var main = <resizable-panel minSize={320}>
			<resizable ref={wb.rowsRef} id="rayde-rows" direction="vertical" class="flex-1 min-h-0">
				<resizable-panel minSize={160}>${wb.editorPart.editorCard()}</resizable-panel>
				<resizable-panel size={wb.panelsPart.problemsHeight} minSize={0} maxSize={480}>${wb.panelsPart.bottomCard()}</resizable-panel>
			</resizable>
		</resizable-panel>;
		var hasSecondary = Lambda.exists(wb.extensionsPart.containers, c -> c.location == "secondary");
		if (hasSecondary)
			return <resizable id="rayde-columns" class="flex-1 min-h-0">
				<resizable-panel size={wb.treeWidth} minSize={Workbench.ACTIVITY} maxSize={Workbench.ACTIVITY + 480}>${sideBar()}</resizable-panel>
				{main}
				<resizable-panel size={wb.secondaryWidth} minSize={0} maxSize={560}>${secondaryBar()}</resizable-panel>
			</resizable>;
		return <resizable id="rayde-columns" class="flex-1 min-h-0">
			<resizable-panel size={wb.treeWidth} minSize={Workbench.ACTIVITY} maxSize={Workbench.ACTIVITY + 480}>${sideBar()}</resizable-panel>
			{main}
		</resizable>;
	}

	/** The project in a pill in the middle, which opens the command center, and the window's controls at one end; the bar moves the window. */
	function titleBar():Element {
		var hint = rayde.Platform.shortcutsMac() ? "⌘P" : "Ctrl+P";
		wb.pill = <div id="rayde-project" class="rayde-pill flex items-center gap-2 px-3 cursor-pointer" width={420} height={26} onPointerDown={e -> e.stopPropagation()} onClick={_ -> if (wb.quickOpen.get()) wb.quickOpen.set(false) else wb.openCenter()}>
			<icon document={Icons.FOLDER_3_LINE} class="rayde-pill-icon size-3.5"/>
			<text class="text-xs flex-1">${wb.props.name}</text>
			<text class="rayde-pill-hint text-xs">${hint}</text>
		</div>;
		return <div id="rayde-bar" class="flex items-center shrink-0" height={40} onPointerDown={barPress}>
			<for {style in [wb.windowStyle.get()]}>${barEnd(style, true)}</for>
			<div class="flex-1"/>
			<tooltip label={"Search files and commands in " + wb.props.display.cwd} side="bottom">{wb.pill}</tooltip>
			<div class="flex-1"/>
			<for {style in [wb.windowStyle.get()]}>${barEnd(style, false)}</for>
		</div>;
	}

	/** One end of the bar: the controls where the style puts them, and on the other end a space of the same width, so the pill stays in the middle. */
	function barEnd(style:String, leftEnd:Bool):Element {
		if (WindowControls.onLeft(style) == leftEnd)
			return <window-controls style={style} chrome={wb.chrome}/>;
		return <div class="shrink-0" width={WindowControls.width(style)}/>;
	}

	/** A press on the bar: a double click maximizes the window, and anything else on it moves the window. */
	function barPress(e:ashui.input.Events.PointerEvent):Void {
		if (e.button == null || !e.button.match(Left))
			return;
		if (e.clickCount >= 2)
			wb.chrome.toggleMaximize();
		else
			wb.chrome.drag();
	}

	/** One of the edges: an invisible strip along a side or a square at a corner, which starts a resize from there. */
	function edge(direction:String):Element {
		var el = <div class="rayde-edge" onPointerDown={e -> if (e.button != null && e.button.match(Left)) {
			e.stopPropagation();
			wb.chrome.resize(direction);
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
			<for {shown in [wb.explorerShown.get()]}>
				<for {build in [wb.buildRevision.get()]}>
					<for {view in [wb.sideView.get()]}>${sideBody(shown, view)}</for>
				</for>
			</for>
		</div>;
	}

	/** What fills the side panel beside the activity bar: the Explorer, or the view of an extension that took its place. */
	function sideBody(shown:Bool, view:String):Element {
		if (!shown)
			return <div/>;
		var registered = wb.contributions.sidebarView(view);
		if (registered != null) return registered();
		var c = Lambda.find(wb.extensionsPart.containers, c -> c.id == view && c.location == "sidebar");
		return c == null ? wb.explorerPart.explorer(shown) : wb.extensionsPart.extensionBody(c, "rayde-explorer");
	}

	/** The right side bar: the extension views that asked to be there, one above the other. */
	function secondaryBar():Element {
		var here = [for (c in wb.extensionsPart.containers) if (c.location == "secondary") c];
		if (here.length == 0)
			return <div/>;
		return <div id="rayde-secondary" class="rayde-card panel flex flex-col flex-1 min-h-0">{[for (c in here) wb.extensionsPart.extensionBody(c, "")]}</div>;
	}

	/** Views down the left edge of the side panel; the Explorer is the one there is, and its icon folds the Explorer away and brings it back. */
	function activityBar():Element
		return <div id="rayde-activity" class="flex flex-col items-center shrink-0 gap-1 py-2" width={Workbench.ACTIVITY}>
			<for {entry in wb.contributions.activityItems("top")}>${activityItem(entry)}</for>
			<div class="flex-1"/>
			<for {entry in wb.contributions.activityItems("bottom")}>${activityItem(entry)}</for>
		</div>;

	function activityItem(entry:ActivityEntry):Element {
		var item = <div id={entry.id} class="rayde-activity-item flex" onClick={_ -> entry.run()}>
			<icon document={entry.icon} class="size-5"/>
		</div>;
		ashui.css.Identity.of(item.tree, item.node.id).bindBooleanAttribute("data-on", Computed.make(() -> entry.on()));
		return <tooltip label={entry.title} side="right">{item}</tooltip>;
	}

	/** An extension's icon: shows its view where it was put, or folds that away when it is showing. */
	public function chooseContainer(c:Container):Void {
		wb.extensionsPart.extensionManager.view(c.extension.id, c.view.id);
		switch c.location {
			case "explorer":
				wb.sideView.set("explorer");
				if (!wb.explorerShown.get()) wb.treeWidth.set(Workbench.ACTIVITY + Workbench.EXPLORER_WIDTH);
			case "sidebar":
				if (wb.sideView.get() == c.id && wb.explorerShown.get())
					wb.treeWidth.set(Workbench.ACTIVITY);
				else {
					wb.sideView.set(c.id);
					if (!wb.explorerShown.get())
						wb.treeWidth.set(Workbench.ACTIVITY + Workbench.EXPLORER_WIDTH);
				}
			case "secondary":
				wb.secondaryWidth.set(wb.secondaryWidth.get() > 0 ? 0 : Workbench.SECONDARY_WIDTH);
			case "panel":
				if (wb.panelsPart.panelShown.get() && wb.panelsPart.bottom.get() == "ext-" + c.id)
					wb.panelsPart.closePanel();
				else
					wb.panelsPart.showPanel("ext-" + c.id);
			case _:
				wb.openFile(wb.containerTab(c));
		}
	}

	/** The runtime the project runs on, the problem counts, and where the run stands. */
	function statusBar():Element
		return <div id="rayde-status-bar" class="rayde-status flex items-center gap-2 px-3 shrink-0" height={28}>
			<for {entry in wb.contributions.statusItems("left")}>${entry.build()}</for>
			<div class="flex-1"/>
			<for {entry in wb.contributions.statusItems("right")}>${entry.build()}</for>
		</div>;
}
