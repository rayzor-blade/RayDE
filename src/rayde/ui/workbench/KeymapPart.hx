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

/** Part of the workbench, split out of it: KeymapPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class KeymapPart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	/** Which key does which command, with the changes kept in .rayde/keybindings.json. */
	var bindings:KeyBindings;

	/** Changes when a key does, so the Settings page draws the keys again. */
	final bindingsRevision = Signal.make(0);

	/** Writes each command's key beside it, as the center shows them; asked again when a binding changes. */
	function refreshShortcuts():Void
		for (a in wb.commandList)
			a.shortcut = bindings.label(a.id);

	/** What follows a change to a key: the center's labels, and the Settings page. */
	function bindingsChanged():Void {
		refreshShortcuts();
		bindingsRevision.set(bindingsRevision.get() + 1);
	}

	/** Whether the key pressed does a command the terminal gives up its keyboard for. */
	function reservedKey(e:KeyEvent):Bool {
		var chord = Chord.ofEvent(e.key, e.shift, e.control, e.alt, e.superKey), id = chord == null ? null : bindings.commandFor(chord);
		return id != null && TerminalPart.terminalKeepsOut.indexOf(id) >= 0;
	}

	/** Group navigation takes precedence over the editor's caret movement keys. */
	function editorKey(e:KeyEvent):Bool {
		var chord = Chord.ofEvent(e.key,e.shift,e.control,e.alt,e.superKey);
		var id = chord == null ? null : bindings.commandFor(chord);
		if (["splitright","splitdown","focusnextgroup","focuspreviousgroup","moveeditorgroup","joingroups","closeeditorgroup"].indexOf(id) < 0) return false;
		key(e); return e.defaultPrevented;
	}

	/** Takes the keys of the keymap `id`, keeps the choice, and shows it everywhere keys are shown. */
	public function useKeymap(id:String):Void {
		bindings.setPreset(id);
		bindings.save(wb.props.display.cwd);
		bindingsChanged();
		wb.say("Keymap: " + Keymaps.find(id).label);
	}

	/** Opens the center to choose a keymap, those of the editors people know. */
	public function selectKeymap():Void
		wb.openPicker("Select a keymap", [
			for (m in Keymaps.available(bindings.mac))
				{id: m.id, label: m.label + (m.id == bindings.preset ? "  (current)" : ""), icon: Icons.KEYBOARD_LINE, run: () -> useKeymap(m.id)}
		]);

	/** Runs the command whose key was pressed: the bindings say which, and the Settings page changes them. */
	function key(e:KeyEvent):Void {
		if (e.defaultPrevented)
			return;
		var chord = Chord.ofEvent(e.key, e.shift, e.control, e.alt, e.superKey);
		if (chord == null)
			return;
		var id = bindings.commandFor(chord);
		var action = id == null ? null : Lambda.find(wb.commandList, a -> a.id == id);
		if (action == null)
			return;
		// The keys of the file commands are the editor's own, copy and paste among them: they are the Explorer's only while it has the keyboard.
		if (Keymaps.fileCommands.indexOf(id) >= 0 && !wb.explorerPart.explorerFocused())
			return;
		action.run();
		e.preventDefault();
	}
}
