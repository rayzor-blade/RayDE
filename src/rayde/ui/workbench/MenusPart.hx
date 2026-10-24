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

/** Part of the workbench, split out of it: MenusPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class MenusPart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	final menuRefs = new Map<Int,Ref<DropdownMenu>>();

	/** Opens or closes the editor actions menu, as its button does. */
	public function showEditorMenu(on:Bool):Void {
		var ref = menuRefs.get(wb.editorPart.groups.current().id);
		if (ref != null && ref.get() != null) ref.get().opened.set(on);
	}

	/** The editor's actions, from the button at the end of the tab strip. */
	function editorMenu(group:rayde.ui.EditorGroups.EditorGroup):Element {
		var menuRef = new Ref<DropdownMenu>();
		menuRefs.set(group.id,menuRef);
		Owner.onCleanup(() -> { if (menuRefs.get(group.id) == menuRef) menuRefs.remove(group.id); });
		var noFile = Computed.make(() -> wb.active.get() == ""), noSaved = Computed.make(() -> wb.open.get().length == wb.dirty.get().length);
		var noGroups = Computed.make(() -> wb.editorPart.groups.all().length < 2);
		var mod = Sys.systemName() == "Mac" ? "⌘" : "Ctrl+";
		return <tooltip label="Editor actions" side="bottom">
			<dropdown-menu ref={menuRef} id="rayde-editor-menu">
				<dropdown-menu-trigger id="rayde-editor-menu-trigger" variant={Ghost} size={Icon} class="rayde-more"><icon document={Icons.MORE_FILL} class="size-4"/></dropdown-menu-trigger>
				<dropdown-menu-content>
					<dropdown-menu-item id="rayde-menu-split-right" shortcut={wb.keymapPart.bindings.label("splitright")} onSelect={() -> wb.editorPart.splitEditor("horizontal")}>Split Editor Right</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-split-down" shortcut={wb.keymapPart.bindings.label("splitdown")} onSelect={() -> wb.editorPart.splitEditor("vertical")}>Split Editor Down</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-move-editor" disabled={noGroups} onSelect={wb.editorPart.moveEditor}>Move Editor to Next Group</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-join-groups" disabled={noGroups} onSelect={wb.editorPart.joinGroups}>Join All Editor Groups</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-close-group" disabled={noGroups} onSelect={wb.editorPart.closeGroup}>Close Editor Group</dropdown-menu-item>
					<dropdown-menu-separator/>
					<dropdown-menu-item id="rayde-menu-save" shortcut={mod + "S"} onSelect={wb.runPart.saveAll}>Save All</dropdown-menu-item>
					<dropdown-menu-separator/>
					<dropdown-menu-item id="rayde-menu-close" shortcut={mod + "W"} disabled={noFile} onSelect={() -> wb.closeFile(wb.active.get())}>Close Tab</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-close-others" disabled={noFile} onSelect={wb.closeOthers}>Close Others</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-close-saved" disabled={noSaved} onSelect={wb.closeSaved}>Close Saved</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-close-all" disabled={Computed.make(() -> wb.open.get().length == 0)} onSelect={wb.closeAll}>Close All</dropdown-menu-item>
					<dropdown-menu-separator/>
					<dropdown-menu-item id="rayde-menu-copy-path" disabled={noFile} onSelect={() -> wb.copyPath(false)}>Copy Path</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-copy-relative" disabled={noFile} onSelect={() -> wb.copyPath(true)}>Copy Relative Path</dropdown-menu-item>
					<for {file in [wb.active.get()]}>${titleItems(file)}</for>
				</dropdown-menu-content>
			</dropdown-menu>
		</tooltip>;
	}

	/** The items an extension adds to the editor's actions menu for the file in front, after a separator; none for a page that is not a file. */
	function titleItems(file:String):Element {
		var entries = Workbench.isVirtual(file) || file == "" ? [] : wb.extensionsPart.contributedMenu("editor/title", file, "file");
		if (entries.length == 0)
			return <div/>;
		var items:Array<Element> = [<dropdown-menu-separator/>];
		for (entry in entries) {
			var e = entry.item, m = entry.extension;
			var icon = ViewIcons.named(m, e.icon), keys = wb.keymapPart.bindings.label(ExtensionsPart.extensionKey(m.id, e.command));
			var label = icon == null ? <text>${e.title}</text> : <div class="flex items-center justify-between gap-3 flex-1 min-w-0"><text>${e.title}</text><icon document={icon} class="size-4 shrink-0 text-text-secondary"/></div>;
			items.push(<dropdown-menu-item id={"rayde-menu-ext-" + (wb.extension != null && m.id == wb.extension.id ? "" : m.id + "-") + e.command} shortcut={keys} onSelect={() -> wb.extensionsPart.runExtensionCommand(m.id, e.command, file)}>${label}</dropdown-menu-item>);
		}
		return <div class="flex flex-col">{items}</div>;
	}

	function desktopMenuBar():Element {
		#if ashui_window
		if (Sys.systemName() != "Mac" || Sys.getEnv("RAYDE_MENU_BAR") == "1") return new DesktopMenus({groups:menuGroups});
		#end
		return <div/>;
	}

	#if ashui_window
	final menuGroups = Signal.make(([]:Array<ashui.app.ApplicationMenu.MenuGroup>));

	function desktopMenus():Array<ashui.app.ApplicationMenu.MenuGroup> {
		var labels = ["save" => "Save", "close" => "Close Tab", "find" => "Find", "replace" => "Replace",
			"splitright" => "Split Editor Right", "splitdown" => "Split Editor Down", "focusnextgroup" => "Focus Next Editor Group", "focuspreviousgroup" => "Focus Previous Editor Group",
			"moveeditorgroup" => "Move Editor to Next Group", "joingroups" => "Join All Editor Groups", "closeeditorgroup" => "Close Editor Group",
			"quickopen" => "Go to File…", "gotoline" => "Go to Line…", "definition" => "Go to Definition",
			"run" => "Run Project", "buildproject" => "Build Project", "stop" => "Stop", "runtask" => "Run Task…", "build" => "Build Settings",
			"terminal" => "Toggle Terminal", "newterminal" => "New Terminal", "splitterminal" => "Split Terminal",
			"panel" => "Toggle Panel", "problems" => "Show Problems", "output" => "Show Output", "extensions" => "Show Extensions"];
		function item(id:String, ?label:String):ashui.app.ApplicationMenu.MenuItem {
			var command = Lambda.find(wb.commandList, c -> c.id == id), chord = wb.keymapPart.bindings.of(id);
			return {label:label != null ? label : command == null ? labels.get(id) : command.label,
				enabled:command != null && (id != "buildproject" || wb.runPart.canBuild() && !wb.runPart.runner.active()), shortcut:wb.keymapPart.bindings.label(id),
				key:chord == null ? null : {key:chord.key, meta:chord.meta, ctrl:chord.ctrl, alt:chord.alt, shift:chord.shift},
				run:command == null ? null : command.run};
		}
		function edit(id:String, label:String, key:String, shift = false):ashui.app.ApplicationMenu.MenuItem {
			var mac = Sys.systemName() == "Mac";
			return {label:label, shortcut:(mac ? "⌘" : "Ctrl+") + (shift ? (mac ? "⇧" : "Shift+") : "") + key.toUpperCase(),
				key:{key:key, meta:mac, ctrl:!mac, alt:false, shift:shift}, run:() -> ashui.input.Keyboard.edit(wb.tree, id)};
		}
		var separator:ashui.app.ApplicationMenu.MenuItem = {separator:true};
		var files = [item("newwindow"), item("newproject"), separator, item("openfolder"), item("openproject"), item("recentprojects"), separator,
			item("save"), {label:"Save All", enabled:wb.dirty.get().length > 0, run:wb.runPart.saveAll}, separator, item("close"), item("closewindow")];
		if (Sys.systemName() != "Mac") files.push({label:"Exit", run:ProjectWindows.quit});
		var windows = [item("minimize"), item("maximize"), item("fullscreen"), separator];
		for (app in ashui.app.WindowedApp.windows()) windows.push({label:app.window.title(), run:() -> app.window.focus()});
		return [
			{label:"File", items:files},
			{label:"Edit", items:[edit("undo","Undo","z"), edit("redo","Redo","z",true), separator,
				edit("cut","Cut","x"), edit("copy","Copy","c"), edit("paste","Paste","v"), separator, edit("selectall","Select All","a"), separator,
				item("find"), item("replace"), item("codeactions"), separator, item("settings")]},
			{label:"View", items:[item("commands"), item("explorer"), item("panel"), separator, item("splitright"), item("splitdown"), item("focusnextgroup"), item("focuspreviousgroup"), item("moveeditorgroup"), item("joingroups"), item("closeeditorgroup"), separator, item("problems"), item("output"), item("extensions"), item("fullscreen")]},
			{label:"Go", items:[item("quickopen"), item("gotoline"), item("definition")]},
			{label:"Run", items:[item("buildproject"), item("run"), item("stop"), separator, item("runtask"), item("build")]},
			{label:"Terminal", items:[item("terminal"), item("newterminal"), item("splitterminal")]},
			{label:"Window", items:windows},
			{label:"Help", items:[item("commands", "Show All Commands"), item("keybindings")]}
		];
	}

	function installDesktopMenus():Void {
		var menu = new ashui.app.ApplicationMenu("RayDE", ProjectWindows.quit);
		new ashui.reactive.Watch(() -> {
			wb.active.get(); wb.dirty.get(); wb.editorPart.groups.layout.get(); wb.keymapPart.bindingsRevision.get(); wb.runPart.runState.get(); wb.buildRevision.get(); ashui.app.WindowedApp.windowRevision.get(); ashui.input.WindowState.active.get();
			return 0;
		}, _ -> { var groups = desktopMenus(); menuGroups.set(groups); menu.update(groups); }, (_, _) -> false);
	}

	#end
}
