package rayde.ui;

import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.input.Events.KeyEvent;
import ashui.input.Interaction;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.keys.Chord;
import rayde.keys.KeyBindings;
import rayde.ui.CommandCenter.CenterAction;

using StringTools;

typedef KeyBindingSettingsProps = {
	bindings:KeyBindings,
	/** The commands that can have a key, in the order the page lists them. */
	commands:Array<CenterAction>,
	root:String,
	/** Called after a binding has changed and been written to the file. */
	onChanged:Void->Void
};

/**
 * Every command and the key that does it, as a list: a click on the key records a new one, the pencil does the
 * same, and a command whose key was changed can be put back. The same key on two commands is marked. Changes go
 * to `.rayde/keybindings.json`; commands the Settings page lists are the ones the command center runs.
 */
class KeyBindingSettings extends Component<KeyBindingSettingsProps> {
	final filter = Signal.make("");
	final revision = Signal.make(0);

	/** The command whose key is being recorded, or an empty string. */
	final recording = Signal.make("");

	/** What the recorder says while it waits: how to finish, or why a key was not taken. */
	final hint = Signal.make("");

	function render():Element
		return SettingsParts.page("rayde-keys", <div class="flex flex-col gap-6">
			${SettingsParts.header(Icons.KEYBOARD_LINE, "Key bindings", ".rayde/keybindings.json. Click a key to record another; the change is written at once.")}
			${SettingsParts.card("rayde-keys-card", "Commands", "The same commands the command center runs.", [filterInput(), listArea()])}
		</div>);

	function filterInput():Element
		return <input height={32} id="rayde-keys-filter" value={filter} placeholder="Search by command or key" class="rayde-control-wide"/>;

	function listArea():Element
		return <div class="flex flex-col"><for {k in [{q: filter.get(), r: revision.get(), c: recording.get()}]}>${list(k.q, k.c)}</for></div>;

	function list(query:String, recordingId:String):Element {
		var q = query.trim().toLowerCase();
		var shown = [for (a in props.commands) if (q == "" || matches(a, q)) a];
		return <div class="flex flex-col gap-2">
			<div class="flex items-center justify-between">
				<text id="rayde-keys-count" class="text-xs text-text-tertiary">${shown.length + (shown.length == 1 ? " command" : " commands")}</text>
				<if {props.bindings.anyChanged()}><button id="rayde-keys-reset-all" variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> resetAll()}>Reset all</button></if>
			</div>
			<div id="rayde-keys-list" class="rayde-key-list flex flex-col overflow-auto">
				<if {shown.length == 0}><div class="px-3 py-3"><text class="text-xs text-text-tertiary">No command matches.</text></div></if>
				{rows(shown, recordingId)}
			</div>
		</div>;
	}

	function rows(shown:Array<CenterAction>, recordingId:String):Array<Element>
		return [for (a in shown) row(a, recordingId == a.id)];

	function matches(a:CenterAction, q:String):Bool {
		var label = props.bindings.label(a.id);
		return a.label.toLowerCase().indexOf(q) >= 0 || a.id.toLowerCase().indexOf(q) >= 0 || label != null && label.toLowerCase().indexOf(q) >= 0;
	}

	function row(a:CenterAction, recordingNow:Bool):Element {
		var chord = props.bindings.of(a.id), changed = props.bindings.changed(a.id);
		var others = [for (id in props.bindings.conflicts(a.id)) labelOf(id)];
		return <div id={"rayde-key-" + a.id} class="rayde-key-row flex items-center gap-3 px-3 shrink-0" height={48}>
			<icon document={a.icon} class="size-4 shrink-0 text-text-tertiary"/>
			<div class="flex flex-col flex-1 min-w-0">
				<text class="text-sm">${a.label}</text>
				<div class="flex items-center gap-2"><text class="rayde-mono text-xs text-text-tertiary">${a.id}</text><if {changed}><text class="text-xs text-primary">Changed</text></if></div>
			</div>
			<if {others.length > 0}><text class="text-xs text-warning">${"Also bound to " + others.join(", ")}</text></if>
			${recordingNow ? recorder(a.id) : keycap(a.id, chord)}
			<div class="rayde-key-tools flex items-center gap-1 shrink-0">
				<tooltip label="Change"><button id={"rayde-key-edit-" + a.id} variant={Ghost} size={Icon} class="rayde-remove" onClick={_ -> start(a.id)}><icon document={Icons.PENCIL_LINE} class="size-4"/></button></tooltip>
				<if {changed}><tooltip label="Reset"><button id={"rayde-key-reset-" + a.id} variant={Ghost} size={Icon} class="rayde-remove" onClick={_ -> reset(a.id)}><icon document={Icons.RESTART_LINE} class="size-4"/></button></tooltip></if>
				<if {chord != null}><tooltip label="Remove"><button id={"rayde-key-remove-" + a.id} variant={Ghost} size={Icon} class="rayde-remove" onClick={_ -> assign(a.id, null)}><icon document={Icons.CLOSE_LINE} class="size-4"/></button></tooltip></if>
			</div>
		</div>;
	}

	function labelOf(id:String):String {
		var a = Lambda.find(props.commands, c -> c.id == id);
		return a == null ? id : a.label;
	}

	function keycap(id:String, chord:Null<Chord>):Element
		return <div id={"rayde-keycap-" + id} class="rayde-keycap flex items-center justify-center px-2 cursor-pointer shrink-0" height={28} onClick={_ -> start(id)}>
			<text class="rayde-mono text-xs">${chord == null ? "Not set" : chord.label(props.bindings.mac)}</text>
		</div>;

	/** The cap while a key is being recorded: it takes the keyboard, and the next chord pressed is the command's. */
	function recorder(id:String):Element {
		var box = <div id="rayde-key-recorder" class="rayde-recorder flex items-center justify-center px-3 shrink-0" height={28}>
			<text class="text-xs">${hint.get() == "" ? "Press the keys, Esc to cancel" : hint.get()}</text>
		</div>;
		var interaction = Interaction.of(box.node).setFocusable(true);
		interaction.onKeyDown(e -> record(id, e));
		var tries = 0, hook:ashui.layout.LayoutTree->Void = null;
		hook = _ -> {
			if (tries++ > 30 || interaction.focused.get()) {
				ashui.layout.LayoutTree.flushHooks.remove(hook);
				return;
			}
			ashui.input.Focus.set(interaction, true);
			// Leaving the recorder, by a click elsewhere, ends the recording.
			if (interaction.focused.get())
				new ashui.reactive.Watch(() -> interaction.focused.get(), on -> if (!on && recording.get() == id) stop(), (_, _) -> false);
		};
		ashui.layout.LayoutTree.flushHooks.push(hook);
		return box;
	}

	function start(id:String):Void {
		hint.set("");
		recording.set(id);
	}

	function stop():Void {
		hint.set("");
		recording.set("");
	}

	/** Takes the chord pressed as the recording command's key; Escape alone cancels. */
	function record(id:String, e:KeyEvent):Void {
		e.preventDefault();
		e.stopPropagation();
		var chord = Chord.ofEvent(e.key, e.shift, e.control, e.alt, e.superKey);
		if (chord == null)
			return;
		if (chord.key == "escape" && !chord.modified() && !chord.shift) {
			stop();
			return;
		}
		// A letter alone is text: a key typed into the editor must not run a command.
		if (!chord.modified() && !~/^f[0-9]+$/.match(chord.key)) {
			hint.set("Hold Ctrl, Alt or Cmd, or use a function key");
			return;
		}
		assign(id, chord);
	}

	function assign(id:String, chord:Null<Chord>):Void {
		props.bindings.set(id, chord);
		commit();
	}

	function reset(id:String):Void {
		props.bindings.reset(id);
		commit();
	}

	function resetAll():Void {
		props.bindings.resetAll();
		commit();
	}

	function commit():Void {
		props.bindings.save(props.root);
		hint.set("");
		recording.set("");
		revision.set(revision.get() + 1);
		props.onChanged();
	}
}
