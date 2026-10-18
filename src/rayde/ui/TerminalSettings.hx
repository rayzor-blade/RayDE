package rayde.ui;

import ashui.components.Icon;
import ashui.components.Select;
import ashui.components.ToggleSwitch;
import ashui.layout.Element;
import ashui.ui.Component;
import rayde.term.Profiles;
import rayde.term.Settings;

typedef TerminalSettingsProps = {
	settings:Settings,
	root:String,
	/** Called after a change has been written to the settings file. */
	onChanged:Void->Void
};

/** The terminal's settings as a form: the profile a new terminal starts from, the cursor's shape, and copying a selection as it is made. */
class TerminalSettings extends Component<TerminalSettingsProps> {
	function render():Element {
		var profiles = Profiles.list();
		var wanted = props.settings.defaultProfile, shown = wanted != null && Lambda.exists(profiles, p -> p.name == wanted) ? wanted : profiles.length > 0 ? profiles[0].name : "";
		var items:Array<Element> = [for (p in profiles) <select-item value={p.name}>${p.name + "  " + p.program}</select-item>];
		return <div id="rayde-terminal-settings" class="rayde-settings flex flex-1 min-h-0 justify-center overflow-auto">
			<div class="flex flex-col gap-6 px-8 py-8" width={780}>
				<div class="flex items-center gap-4">
					<div class="rayde-tile flex items-center justify-center shrink-0" width={44} height={44}><icon document={Icons.TERMINAL_BOX_LINE} class="size-5"/></div>
					<div class="flex flex-col gap-1">
						<text class="text-2xl font-semibold tracking-tighter">Terminal</text>
						<text class="text-sm text-text-secondary">.rayde/terminal.json. Each change is written to the file at once.</text>
					</div>
				</div>
				<div class="rayde-setting-card flex flex-col gap-4 p-5">
					<div class="flex flex-col gap-1">
						<text class="text-sm font-semibold">Profile</text>
						<text class="text-xs text-text-tertiary">${"What + starts. The shells come from $SHELL and /etc/shells."}</text>
					</div>
					${field("Default profile", "Started by + and Ctrl+Shift+`",
						<select id="rayde-terminal-default" value={shown} size={Sm} class="rayde-control-wide" onChange={name -> change(() -> props.settings.defaultProfile = name)}>{items}</select>)}
				</div>
				<div class="rayde-setting-card flex flex-col gap-4 p-5">
					<div class="flex flex-col gap-1">
						<text class="text-sm font-semibold">Screen</text>
						<text class="text-xs text-text-tertiary">How the terminal draws and what it does with the pointer.</text>
					</div>
					${field("Cursor", "The shape of the cursor while the terminal has the keyboard",
						<select id="rayde-terminal-cursor" value={props.settings.cursor} size={Sm} class="rayde-control" onChange={v -> change(() -> props.settings.cursor = v)}>
							<select-item value="block">Block</select-item>
							<select-item value="bar">Bar</select-item>
							<select-item value="underline">Underline</select-item>
						</select>)}
					${field("Copy on selection", "A selection is on the clipboard as soon as the pointer lets go",
						<toggle-switch id="rayde-terminal-copy" checked={props.settings.copyOnSelect} size={Sm} onChange={on -> change(() -> props.settings.copyOnSelect = on)}/>)}
				</div>
				<div class="shrink-0" height={40}/>
			</div>
		</div>;
	}

	function change(edit:Void->Void):Void {
		edit();
		props.settings.save(props.root);
		props.onChanged();
	}

	function field(label:String, hint:String, control:Element):Element
		return <div class="flex items-center justify-between gap-6">
			<div class="flex flex-col gap-1 min-w-0">
				<text class="text-sm">${label}</text>
				<text class="text-xs text-text-tertiary">${hint}</text>
			</div>
			<div class="shrink-0">${control}</div>
		</div>;
}
