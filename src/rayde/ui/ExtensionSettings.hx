package rayde.ui;

import ashui.components.Icon;
import ashui.layout.Element;
import ashui.ui.Component;
import rayde.settings.Extensions;
import rayde.settings.Extensions.Extension;

typedef ExtensionSettingsProps = {root:String};

/** The extensions installed, from the folders that hold an extension.json. */
class ExtensionSettings extends Component<ExtensionSettingsProps> {
	function render():Element {
		var found = Extensions.list(props.root);
		return SettingsParts.page("rayde-extensions", <div class="flex flex-col gap-6">
			${SettingsParts.header(Icons.PUZZLE_LINE, "Extensions", "Folders with an extension.json, in .rayde/extensions here or in your home folder.")}
			${SettingsParts.card("rayde-extensions-card", "Installed", "RayDE lists what it finds. It does not run extensions yet.", rows(found))}
		</div>);
	}

	function rows(found:Array<Extension>):Array<Element>
		return found.length == 0 ? [empty()] : [for (e in found) row(e)];

	function empty():Element
		return <div class="flex flex-col gap-1 py-2">
			<text id="rayde-extensions-empty" class="text-sm text-text-secondary">No extensions installed.</text>
			<text class="text-xs text-text-tertiary">To add one, put its folder in .rayde/extensions.</text>
		</div>;

	function row(e:Extension):Element
		return <div id={"rayde-extension-" + e.id} class="rayde-setting-row flex items-center gap-3 px-3 shrink-0" height={56}>
			<icon document={Icons.PUZZLE_LINE} class="size-4 shrink-0 text-text-secondary"/>
			<div class="flex flex-col flex-1 min-w-0">
				<text class="text-sm">${e.version == "" ? e.name : e.name + "  " + e.version}</text>
				<text class="text-xs text-text-tertiary">${e.problem != null ? e.problem : e.description == "" ? e.path : e.description}</text>
			</div>
			<text class="text-xs text-text-tertiary">${e.scope}</text>
		</div>;
}
