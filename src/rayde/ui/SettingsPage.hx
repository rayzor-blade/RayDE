package rayde.ui;

import ashui.components.Icon;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.build.HxmlFile;
import rayde.ext.Manifest;
import rayde.keys.KeyBindings;
import rayde.run.LibraryManager;
import rayde.settings.Appearance;
import rayde.term.Settings;
import rayde.ui.AppearanceSettings;
import rayde.ui.BuildSettings;
import rayde.ui.CommandCenter.CenterAction;
import rayde.ui.ExtensionConfig;
import rayde.ui.ExtensionSettings;
import rayde.ui.KeyBindingSettings;
import rayde.ui.LibrarySettings;
import rayde.ui.TerminalSettings;

/** A section of the Settings page: the id the workbench opens it by, and what the list beside the page calls it. */
typedef SettingsCategory = {id:String, label:String, icon:ashui.svg.SvgDocument};

typedef SettingsPageProps = {
	/** The section in view, which the workbench keeps so it is the same when the page is made again. */
	category:Signal<String>,
	root:String,
	/** The build file the Build section edits; null when the project has none. */
	build:Null<HxmlFile>,
	terminal:Settings,
	appearance:Appearance,
	bindings:KeyBindings,
	/** Changes when the keys do, from the page or elsewhere. */
	bindingChanges:Signal<Int>,
	commands:Array<CenterAction>,
	libraries:LibraryManager,
	onBuildChanged:Void->Void,
	onTerminalChanged:Void->Void,
	onAppearanceChanged:Void->Void,
	onBindingsChanged:Void->Void,
	/** The extension this project is, when it is one: its config is a section, and the build and libraries are not. */
	extension:Null<Manifest>,
	onExtensionChanged:Manifest->Void,
	onEditExtensionText:Void->Void,
	/** The hooks the extension running now listens for. */
	?listening:Void->Array<String>
};

/**
 * The workspace's settings: a list of sections down the left and the one chosen beside it, as VS Code's
 * Settings editor. Build and Libraries are the project's own; Terminal, Color scheme and Key bindings are
 * how the workbench looks and behaves here; Extensions lists what is installed.
 */
class SettingsPage extends Component<SettingsPageProps> {
	public static final categories:Array<SettingsCategory> = [
		{id: "extension", label: "Extension", icon: Icons.PUZZLE_LINE},
		{id: "build", label: "Build", icon: Icons.HAMMER_LINE},
		{id: "libraries", label: "Libraries", icon: Icons.BOOK_2_LINE},
		{id: "terminal", label: "Terminal", icon: Icons.TERMINAL_BOX_LINE},
		{id: "appearance", label: "Color scheme", icon: Icons.PALETTE_LINE},
		{id: "keys", label: "Key bindings", icon: Icons.KEYBOARD_LINE},
		{id: "extensions", label: "Extensions", icon: Icons.PUZZLE_LINE}
	];

	/** The section named `id`, or the first a Haxe project has. */
	public static function category(id:String):SettingsCategory {
		var found = Lambda.find(categories, c -> c.id == id);
		return found == null ? categories[1] : found;
	}

	/** Whether a project has the section: the config of an extension only for an extension, the build and libraries for the rest. */
	function has(c:SettingsCategory):Bool
		return props.extension != null ? c.id != "build" && c.id != "libraries" : c.id != "extension";

	function render():Element
		return <div id="rayde-settings" class="flex flex-1 min-h-0">
			<div id="rayde-settings-nav" class="rayde-settings-nav flex flex-col shrink-0 gap-1 px-3 py-4" width={216}>
				<for {id in [props.category.get()]}>${nav(id)}</for>
			</div>
			<for {id in [props.category.get()]}>${section(id)}</for>
		</div>;

	function nav(current:String):Element
		return <div class="flex flex-col gap-1">{[for (c in categories) if (has(c)) navItem(c, c.id == current)]}</div>;

	function navItem(c:SettingsCategory, on:Bool):Element {
		var item = <div id={"rayde-settings-nav-" + c.id} class="rayde-nav-item flex items-center gap-3 px-3 cursor-pointer" height={34} onClick={_ -> props.category.set(c.id)}>
			<icon document={c.icon} class="size-4 shrink-0"/>
			<text class="text-sm">${c.label}</text>
		</div>;
		if (on)
			ashui.css.Identity.of(item.tree, item.node.id).setAttribute("data-on", "");
		return item;
	}

	/** The chosen section, which fills what the list leaves. */
	function section(id:String):Element
		return switch id {
			case "libraries": <library-settings file={props.build} root={props.root} manager={props.libraries} onChanged={props.onBuildChanged}/>;
			case "terminal": <terminal-settings settings={props.terminal} root={props.root} onChanged={props.onTerminalChanged}/>;
			case "appearance": <appearance-settings appearance={props.appearance} root={props.root} onChanged={props.onAppearanceChanged}/>;
			case "keys": <key-binding-settings bindings={props.bindings} commands={props.commands} root={props.root} onChanged={props.onBindingsChanged} changes={props.bindingChanges}/>;
			case "extensions": <extension-settings root={props.root}/>;
			case "extension" if (props.extension != null): <extension-config manifest={props.extension} onChanged={props.onExtensionChanged} onEditText={props.onEditExtensionText} listening={props.listening}/>;
			case _: props.build == null ? noBuild() : <build-settings file={props.build} root={props.root} onChanged={props.onBuildChanged}/>;
		}

	/** The Build section of a project opened without a build file. */
	function noBuild():Element
		return SettingsParts.page("rayde-build", <div class="flex flex-col gap-6">
			${SettingsParts.header(Icons.HAMMER_LINE, "Build", "This project has no build file.")}
			<div class="rayde-note flex items-center gap-3 px-4 py-3"><icon document={Icons.INFORMATION_LINE} class="size-4 shrink-0"/><text class="text-xs">Open RayDE on a .hxml file to edit how the project builds.</text></div>
		</div>);
}
