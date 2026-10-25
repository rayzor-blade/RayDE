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

/** Part of the workbench, split out of it: PanelsPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class PanelsPart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	/** The bottom panel's height: 0 while it is closed, which is how it starts. */
	final problemsHeight = Signal.make(0.);

	/** Its height when it was last open, which opening it again goes back to. */
	var panelHeight = 190.;

	var panelShown:Computed<Bool>;

	/** The tab shown below the editor: problems, console (which the panel calls Output), terminal or extension. */
	public final bottom = Signal.make("problems");

	var problemScrollY = 0.;

	var problemScrollCount = 0;

	/** Sets the bottom panel's height, as a drag of its handle would. */
	public function setPanelHeight(height:Float):Void
		problemsHeight.set(height);

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
			var rows = wb.rowsRef.get();
			if (rows != null)
				for (id in ashui.css.Css.query(rows.tree, rows.node.id, "#rayde-rows > .ui-resizable-handle"))
					ashui.css.Identity.of(rows.tree, id).setAttribute("data-closed", shown ? null : "");
		};
		ashui.layout.LayoutTree.flushHooks.push(hook);
	}

	/** Problems and the Output of a run, as VS Code's panel names them. */
	/** What a view the extension put in the bottom panel shows, under its tab. */
	function panelContent(c:Container):Element
		return <tabs-content value={"ext-" + c.id} class="flex-1 min-h-0 pt-1">${wb.extensionsPart.extensionBody(c, "")}</tabs-content>;

	function bottomCard():Element
		return <div id="rayde-panel" class="rayde-card panel relative flex flex-col flex-1 min-h-0">
			<tabs id="rayde-bottom" value={bottom} size={Sm} class="flex-1 min-h-0 px-2 pt-2">
				<tabs-list class="shrink-0">
					<tabs-trigger id="rayde-tab-problems" value="problems">Problems</tabs-trigger>
					<tabs-trigger id="rayde-tab-console" value="console">Output</tabs-trigger>
					<tabs-trigger id="rayde-tab-terminal" value="terminal">Terminal</tabs-trigger>
					<tabs-trigger id="rayde-tab-extension" value="extension">Extension</tabs-trigger>
					{[for (c in wb.extensionsPart.containers) if (c.location == "panel") <tabs-trigger id={"rayde-tab-" + c.id} value={"ext-" + c.id}>${c.title}</tabs-trigger>]}
				</tabs-list>
				<tabs-content value="problems" class="flex-1 min-h-0 pt-1"><if {panelShown.get() && bottom.get() == "problems"}><for {list in [wb.problems.get()]}>${problemsPane(list)}</for></if></tabs-content>
				<tabs-content value="console" class="flex-1 min-h-0 pt-1">
					<if {panelShown.get() && bottom.get() == "console"}>${outputPane()}</if>
				</tabs-content>
				<tabs-content value="terminal" class="flex-1 min-h-0 pt-1"><for {g in [wb.terminalPart.terminalGeneration.get()]}>${wb.terminalPart.terminalPane()}</for></tabs-content>
				<tabs-content value="extension" class="flex-1 min-h-0 pt-1"><studio-panels studio={wb.extensionsPart.activeStudio} onOpen={wb.goTo}/></tabs-content>
				{[for (c in wb.extensionsPart.containers) if (c.location == "panel") panelContent(c)]}
			</tabs>
			<div class="flex items-center gap-1" position={Absolute} right={8} top={6}>
				<for {tab in [bottom.get()]}>${panelTools(tab)}</for>
				<tooltip label="Close panel" side="top"><button id="rayde-panel-close" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> closePanel()}><icon document={Icons.CLOSE_LINE} class="size-4"/></button></tooltip>
			</div>
		</div>;

	function outputPane():Element {
		var items:Array<Element> = [<select-item value="build">Build</select-item>];
		for (e in wb.extensionsPart.extensionManager.extensions) items.push(<select-item value={"ext:" + e.installed.id}>${e.installed.name}</select-item>);
		return <div class="flex flex-col flex-1 min-h-0 gap-2">
			<select id="rayde-output-channel" value={wb.extensionsPart.outputChannel.get()} size={Sm} class="rayde-control-wide" onChange={value -> { wb.extensionsPart.outputChannel.set(value); wb.extensionsPart.refreshExtensionOutput(); }}>{items}</select>
			<for {channel in [wb.extensionsPart.outputChannel.get()]}>
				{channel == "build" ? wb.runPart.buildLog() : wb.extensionsPart.extensionLog()}
			</for>
		</div>;
	}

	/** What the panel's tab row holds for the tab in view, before its close button: for the terminal, + and the menu beside it, and a bin. */
	function panelTools(tab:String):Element {
		if (tab != "terminal")
			return <div/>;
		var mod = rayde.Platform.shortcutsMac() ? "⌘" : "Ctrl+";
		return <div class="flex items-center gap-1">
			<div class="flex items-center">
				<tooltip label="New terminal" side="top"><button id="rayde-terminal-add" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> wb.terminalPart.newTerminal()}><icon document={Icons.ADD_LINE} class="size-4"/></button></tooltip>
				<dropdown-menu ref={wb.terminalPart.profilesMenu} id="rayde-terminal-profiles">
					<dropdown-menu-trigger id="rayde-terminal-profiles-trigger" variant={Ghost} size={Icon} class="rayde-panel-button rayde-split"></dropdown-menu-trigger>
					<dropdown-menu-content>
						<if {wb.terminalPart.profilesMenu.get() != null && wb.terminalPart.profilesMenu.get().opened.get()}>
						<dropdown-menu-item id="rayde-menu-new-terminal" shortcut="Ctrl+Shift+`" onSelect={() -> wb.terminalPart.newTerminal()}>New Terminal</dropdown-menu-item>
						<dropdown-menu-item id="rayde-menu-split-terminal" shortcut={wb.keymapPart.bindings.label("splitterminal")} onSelect={() -> wb.terminalPart.splitTerminal()}>Split Terminal</dropdown-menu-item>
						<dropdown-menu-separator/>
						<dropdown-menu-label>Profiles</dropdown-menu-label>
						{wb.terminalPart.profileItems()}
						<dropdown-menu-separator/>
						<dropdown-menu-item id="rayde-menu-split-profile" onSelect={wb.terminalPart.splitWithProfile}>Split Terminal with Profile…</dropdown-menu-item>
						<dropdown-menu-item id="rayde-menu-default-profile" onSelect={wb.terminalPart.selectDefaultProfile}>Select Default Profile…</dropdown-menu-item>
						<dropdown-menu-item id="rayde-menu-terminal-settings" onSelect={wb.terminalPart.openTerminalSettings}>Configure Terminal Settings</dropdown-menu-item>
						<dropdown-menu-separator/>
						<dropdown-menu-item id="rayde-menu-run-task" onSelect={wb.runPart.runTaskPicker}>Run Task…</dropdown-menu-item>
						<dropdown-menu-item id="rayde-menu-configure-tasks" onSelect={wb.runPart.configureTasks}>Configure Tasks…</dropdown-menu-item>
						</if>
					</dropdown-menu-content>
				</dropdown-menu>
			</div>
			<tooltip label="Kill terminal" side="top"><button id="rayde-terminal-kill" variant={Ghost} size={Icon} class="rayde-panel-button rayde-remove" onClick={_ -> wb.terminalPart.killTerminal()}><icon document={Icons.DELETE_BIN_LINE} class="size-4"/></button></tooltip>
		</div>;
	}

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
		var row = <div class="rayde-problem flex items-center gap-2 px-2 py-1 shrink-0" height={28} onClick={_ -> { if (located) wb.goTo(p.file, p.range.start.line, p.range.start.character); }}>
			<if {p.severity == 1}><icon document={Icons.CLOSE_CIRCLE_LINE} class="size-4 text-error"/>
			<else><icon document={Icons.ALERT_LINE} class="size-4 text-warning"/></if>
			<text class="text-xs flex-1 min-w-0">${p.message.split("\n")[0]}</text>
			<text class="text-xs text-text-tertiary">${location}</text>
		</div>;
		if (located) ashui.css.Identity.of(row.tree, row.node.id).addClasses(["cursor-pointer"]);
		return row;
	}

	function problemCounts(list:Array<Diagnostic>):Element {
		var errors = Lambda.count(list, p -> p.severity == 1), warnings = Lambda.count(list, p -> p.severity == 2);
		return <tooltip label="Problems in the open files" side="top">
			<div id="rayde-problem-counts" class="rayde-status-item action flex" onClick={_ -> showPanel("problems")}>
				<if {errors > 0}><icon document={Icons.CLOSE_CIRCLE_LINE} class="size-3.5 text-error"/><text class="text-error">${errors}</text>
				<else><icon document={Icons.CLOSE_CIRCLE_LINE} class="size-3.5"/><text>${errors}</text></if>
				<if {warnings > 0}><icon document={Icons.ALERT_LINE} class="size-3.5 text-warning"/><text class="text-warning">${warnings}</text>
				<else><icon document={Icons.ALERT_LINE} class="size-3.5"/><text>${warnings}</text></if>
			</div>
		</tooltip>;
	}
}
