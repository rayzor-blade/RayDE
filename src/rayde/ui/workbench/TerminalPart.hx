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

/** Part of the workbench, split out of it: TerminalPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class TerminalPart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	/** The commands whose keys the terminal leaves to the workbench while it has the keyboard; any other key is the program's. */
	static final terminalKeepsOut = ["terminal", "newterminal", "splitterminal", "panel", "quickopen", "commands", "settings"];

	/** The program the terminal runs, the user's login shell unless a test names one. */
	public var terminalProgram:Null<String>;

	public var terminalArgs:Null<Array<String>>;

	var sessions:Array<Session> = [];

	var activeSession = -1;

	var nextSession = 1;

	var nextGroup = 1;

	/** What the terminal is set to, read from the project's .rayde/terminal.json. */
	var terminalSettings:Settings;

	/** Changes when a terminal setting does, for the views that draw by it. */
	final settingsRevision = Signal.make(0);

	/** The terminal in front, by id, for the list beside the screens. */
	final terminalActive = Signal.make(-1);

	final views = new Map<Int, Ref<TerminalView>>();

	/** Set while a new terminal is being made on purpose, so showing the panel does not also start one. */
	var starting = false;

	final terminalGeneration = Signal.make(0);

	final terminalView = new Ref<TerminalView>();

	final profilesMenu = new Ref<DropdownMenu>();

	function current():Null<Session>
		return find(activeSession);

	function find(id:Int):Null<Session> {
		for (s in sessions)
			if (s.id == id)
				return s;
		return null;
	}

	/** The terminal in view, null when none runs. */
	public function terminal():Null<Terminal> {
		var s = current();
		return s == null ? null : s.terminal;
	}

	/** How many terminals are running. */
	public function terminalCount():Int
		return sessions.length;

	/** The ids of the terminals running, in the order they were started. */
	public function terminalIds():Array<Int>
		return [for (s in sessions) s.id];

	/** The terminals that share a screen with `id`, from left to right: the one itself when it is not split. */
	function groupOf(id:Int):Array<Session> {
		var s = find(id);
		return s == null ? [] : [for (o in sessions) if (o.group == s.group) o];
	}

	/** Ends every terminal. */
	public function closeTerminals():Void
		for (id in terminalIds())
			endSession(id);

	/** The profile a plain + starts: the one set as the default, else the first the machine offers, unless a test names a program. */
	function defaultProfile():Profile {
		if (terminalProgram != null)
			return {name: haxe.io.Path.withoutDirectory(terminalProgram), program: terminalProgram, args: terminalArgs};
		var all = Profiles.list();
		for (p in all)
			if (p.name == terminalSettings.defaultProfile)
				return p;
		return all.length > 0 ? all[0] : {name: "sh", program: "/bin/sh"};
	}

	/** Starts the first terminal if none runs. */
	function ensureTerminal():Void
		if (!starting && sessions.length == 0)
			startSession(defaultProfile());

	/** Runs `profile` in the project's folder, on the screen of `group` or a new one, and brings it to the front. */
	function startSession(profile:Profile, ?group:Int):Void {
		var t = Terminal.open(100, 12, wb.props.display.cwd, profile.program, profile.args, true);
		if (t == null) {
			wb.say("Could not start " + profile.name);
			return;
		}
		var session = {id: nextSession++, group: group == null ? nextGroup++ : group, terminal: t, profile: profile};
		sessions.push(session);
		activeSession = session.id;
		terminalActive.set(session.id);
		terminalGeneration.set(terminalGeneration.get() + 1);
	}

	/** Starts another terminal on a screen of its own, from `profile` or the default, beside the ones running, and gives it the keyboard. */
	public function newTerminal(?profile:Profile):Void {
		starting = true;
		wb.panelsPart.showPanel("terminal");
		starting = false;
		startSession(profile == null ? defaultProfile() : profile);
		focusTerminal();
	}

	/** Splits the screen of the terminal in front, adding one beside it from `profile` or the same profile. */
	public function splitTerminal(?profile:Profile):Void {
		var s = current();
		if (s == null) {
			newTerminal(profile);
			return;
		}
		if (groupOf(s.id).length >= Workbench.MAX_SPLITS) {
			wb.say("A screen is split " + Workbench.MAX_SPLITS + " ways at most");
			return;
		}
		startSession(profile == null ? s.profile : profile, s.group);
		focusTerminal();
	}

	/** Brings terminal `id` to the front, and its screen with it. */
	public function selectTerminal(id:Int):Void {
		var from = current(), to = find(id);
		if (to == null)
			return;
		activeSession = id;
		terminalActive.set(id);
		if (from == null || from.group != to.group)
			terminalGeneration.set(terminalGeneration.get() + 1);
		focusTerminal();
	}

	/** Notes that the view of terminal `id` has the keyboard, which makes it the one in front. */
	function noteFocus(id:Int):Void
		if (activeSession != id && find(id) != null) {
			activeSession = id;
			terminalActive.set(id);
		}

	/** Ends the terminal in front; one beside it, or the neighbouring screen, comes forward, and with none left the pane offers a new one. */
	public function killTerminal():Void
		endSession(activeSession);

	function endSession(id:Int):Void {
		var at = -1;
		for (i => s in sessions)
			if (s.id == id)
				at = i;
		if (at < 0)
			return;
		var group = sessions[at].group;
		sessions[at].terminal.close();
		sessions.splice(at, 1);
		views.remove(id);
		if (activeSession == id) {
			var peers = [for (s in sessions) if (s.group == group) s];
			activeSession = peers.length > 0 ? peers[peers.length - 1].id : sessions.length == 0 ? -1 : sessions[Std.int(Math.min(at, sessions.length - 1))].id;
			terminalActive.set(activeSession);
		}
		terminalGeneration.set(terminalGeneration.get() + 1);
	}

	/** Makes `name` the profile + starts, and keeps it. */
	public function setDefaultProfile(name:String):Void {
		terminalSettings.defaultProfile = name;
		terminalSettings.save(wb.props.display.cwd);
		settingsRevision.set(settingsRevision.get() + 1);
	}

	/** Opens or closes the menu of terminal profiles, as its button does. */
	public function showTerminalMenu(on:Bool):Void
		if (profilesMenu.get() != null)
			profilesMenu.get().opened.set(on);

	/** Opens the Settings page on the terminal's section. */
	public function openTerminalSettings():Void
		wb.openSettings("terminal");

	/** The profiles of the machine as choices, each doing `then` with its profile when chosen. */
	function profileChoices(then:Profile->Void):Array<CenterAction> {
		var out:Array<CenterAction> = [];
		for (p in Profiles.list())
			out.push({
				id: "profile-" + p.name,
				label: p.name + (p.name == defaultProfile().name ? " (default)" : ""),
				icon: p.name == defaultProfile().name ? Icons.CHECK_LINE : Icons.TERMINAL_BOX_LINE,
				shortcut: p.program,
				run: () -> then(p)
			});
		return out;
	}

	public function splitWithProfile():Void
		wb.openPicker("Split the terminal with a profile", profileChoices(p -> splitTerminal(p)));

	public function selectDefaultProfile():Void
		wb.openPicker("Select the default profile", profileChoices(p -> setDefaultProfile(p.name)));

	/** Opens the panel on the terminal and gives it the keyboard, or closes the panel when the terminal is what it shows. */
	public function toggleTerminal():Void {
		if (wb.panelsPart.panelShown.get() && wb.panelsPart.bottom.get() == "terminal") {
			wb.panelsPart.closePanel();
			return;
		}
		wb.panelsPart.showPanel("terminal");
		focusTerminal();
	}

	/** Once the view of the terminal in front is made, gives it the keyboard. */
	public function focusTerminal():Void {
		var tries = 0, hook:ashui.layout.LayoutTree->Void = null;
		hook = _ -> {
			var ref = views.get(activeSession), view = ref == null ? null : ref.get();
			if (view != null && wb.panelsPart.panelShown.get()) {
				ashui.layout.LayoutTree.flushHooks.remove(hook);
				view.focus();
			} else if (++tries > 30)
				ashui.layout.LayoutTree.flushHooks.remove(hook);
		};
		ashui.layout.LayoutTree.flushHooks.push(hook);
	}

	/** The screen of the terminal in front, split with its neighbours when it is, and the list of terminals beside it when there are several; or an offer of one while none is running. */
	function terminalPane():Element {
		var session = current();
		if (session == null)
			return <div id="rayde-terminal-empty" class="flex flex-col flex-1 items-center justify-center gap-3">
				<text class="text-sm text-text-tertiary">No terminal is running.</text>
				<button id="rayde-terminal-new" variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> newTerminal()}>New terminal</button>
			</div>;
		var members = groupOf(session.id);
		// A view that takes a terminal over from another shows all of its rows.
		for (m in members)
			m.terminal.invalidate();
		return <div class="flex flex-1 min-h-0 min-w-0">
			${screens(members)}
			<if {sessions.length > 1}><for {id in [terminalActive.get()]}>${terminalList()}</for></if>
		</div>;
	}

	/** One screen, or several side by side with a divider to drag between each two. */
	function screens(members:Array<Session>):Element {
		if (members.length == 1)
			return screen(members[0]);
		return <resizable id="rayde-terminal-split" class="flex-1 min-h-0 min-w-0">{splitPanels(members)}</resizable>;
	}

	function splitPanels(members:Array<Session>):Array<Element>
		return [for (m in members) <resizable-panel minSize={140}>${screen(m)}</resizable-panel>];

	function screen(s:Session):Element {
		var ref = views.get(s.id);
		if (ref == null) {
			ref = new Ref<TerminalView>();
			views.set(s.id, ref);
		}
		var id = s.id;
		return <terminal-view ref={ref} terminal={s.terminal} shown={() -> wb.panelsPart.panelShown.get() && wb.panelsPart.bottom.get() == "terminal"} settings={terminalSettings} changes={settingsRevision}
			onExit={code -> wb.say(s.terminal.failedToStart() ? "Could not start " + s.profile.name : s.profile.name + " exited with code " + code)} onFocus={() -> noteFocus(id)} reserved={wb.keymapPart.reservedKey}/>;
	}

	/** The terminals running down the right of the pane, a screen's terminals together; the one in front lit. */
	function terminalList():Element
		return <div id="rayde-terminal-list" class="rayde-term-list flex flex-col shrink-0 gap-1 p-1" width={170}>{terminalRows()}</div>;

	function terminalRows():Array<Element> {
		var out = [], seen = new Map<Int, Bool>();
		for (s in sessions) {
			out.push(terminalRow(s, seen.exists(s.group)));
			seen.set(s.group, true);
		}
		return out;
	}

	function terminalRow(s:Session, split:Bool):Element {
		var id = s.id, row = <div id={"rayde-terminal-item-" + id} class="rayde-term-item flex items-center gap-2 px-2 shrink-0 cursor-pointer" height={28} onClick={_ -> selectTerminal(id)}>
			<icon document={split ? Icons.LAYOUT_COLUMN_LINE : Icons.TERMINAL_BOX_LINE} class="size-4 shrink-0"/>
			<text class="text-xs flex-1 min-w-0">${s.profile.name}</text>
			<tooltip label="Kill terminal" side="left"><button variant={Ghost} size={Icon} class="rayde-remove rayde-term-kill" onClick={e -> {
				e.stopPropagation();
				endSession(id);
			}}><icon document={Icons.CLOSE_LINE} class="size-3.5"/></button></tooltip>
		</div>;
		var identity = ashui.css.Identity.of(row.tree, row.node.id);
		if (s.id == activeSession)
			identity.setAttribute("data-on", "");
		if (split)
			identity.setAttribute("data-split", "");
		return row;
	}

	/** One item for each shell the machine has, with where it is, the default marked. */
	function profileItems():Array<Element> {
		var selected = defaultProfile().name;
		return [for (p in Profiles.list()) profileItem(p, selected)];
	}

	function profileItem(p:Profile, selected:String):Element
		return <dropdown-menu-item id={"rayde-profile-" + p.name} shortcut={p.program} onSelect={() -> newTerminal(p)}>${p.name == selected ? p.name + " (default)" : p.name}</dropdown-menu-item>;
}
