package rayde.ui;

import ashui.components.Icon;
import ashui.components.ToggleSwitch;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.ext.Manager;
import rayde.ext.Manager.ManagedExtension;
import rayde.ui.ExtensionConfiguration;

typedef ExtensionSettingsProps = {root:String, manager:Manager, changes:Signal<Int>, onToggle:(String, Bool)->Void};

/** Installed extensions, their runtime state, and their configuration schemas. */
class ExtensionSettings extends Component<ExtensionSettingsProps> {
	function render():Element
		return SettingsParts.page("rayde-extensions", <div class="flex flex-col gap-6">
			${SettingsParts.header(Icons.PUZZLE_LINE, "Extensions", "Built-in, user and workspace extensions. Workspace settings override user settings.")}
			<for {revision in [props.changes.get()]}>${installed()}</for>
		</div>);

	function installed():Element {
		var rows = [for (e in props.manager.extensions) row(e)];
		if (rows.length == 0) rows.push(<text id="rayde-extensions-empty" class="text-sm text-text-secondary">No extensions installed.</text>);
		return <div class="flex flex-col gap-4">{rows}</div>;
	}

	function row(e:ManagedExtension):Element {
		var m = e.connection.manifest;
		var details:Array<Element> = [
			<div class="flex items-center gap-3">
				<icon document={Icons.PUZZLE_LINE} class="size-4 shrink-0 text-text-secondary"/>
				<div class="flex flex-col flex-1 min-w-0">
					<text class="text-sm">${m.version == "" ? m.name : m.name + "  " + m.version}</text>
					<text class="text-xs text-text-tertiary">${e.installed.scope + " · " + e.state}</text>
				</div>
				<toggle-switch id={"rayde-extension-toggle-" + e.installed.id} checked={!e.disabled} size={Sm} onChange={on -> props.onToggle(e.installed.id, !on)}/>
			</div>,
			<text class="text-xs text-text-secondary">${e.installed.problem ?? (m.description == "" ? e.installed.path : m.description)}</text>,
			<text class="text-xs text-text-tertiary">${"Activation: " + (e.activation ?? (m.activationEvents ?? ["onStartup"]).join(", "))}</text>,
			<text class="text-xs text-text-tertiary">${"Host: " + e.connection.state}</text>,
			<text class="text-xs text-text-tertiary">${"Capabilities: " + (m.capabilities.length == 0 ? "none" : m.capabilities.join(", "))}</text>
		];
		if (m.configuration != null) details.push(<extension-configuration root={props.root} id={m.id} schema={m.configuration}/>);
		return SettingsParts.card("rayde-extension-" + e.installed.id, m.name, e.installed.path, details);
	}
}
