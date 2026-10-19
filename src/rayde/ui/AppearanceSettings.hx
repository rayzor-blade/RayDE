package rayde.ui;

import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Select;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.theme.ColorToken;
import ashui.ui.Component;
import rayde.settings.Appearance;
import rayde.settings.Appearance.ThemeChoice;
import rayde.theme.Themes;

typedef AppearanceSettingsProps = {
	appearance:Appearance,
	root:String,
	/** Called after a change has been applied and written to the settings file. */
	onChanged:Void->Void
};

/**
 * The colour scheme as a form: light, dark or the system's, and a theme chosen from a picture of each. A choice
 * is put on the window at once and written to the `appearance` section of the settings file.
 */
class AppearanceSettings extends Component<AppearanceSettingsProps> {
	final revision = Signal.make(0);
	final themePath = Signal.make("");

	/** What the last install or removal said, a line each. */
	var notes:Array<String> = [];

	function render():Element
		return SettingsParts.page("rayde-appearance", <div class="flex flex-col gap-6">
			${SettingsParts.header(Icons.PALETTE_LINE, "Color scheme", ".rayde/settings.json. A choice is applied to this window and written to the file at once.")}
			<for {r in [revision.get()]}>${sections(r)}</for>
		</div>);

	function sections(_:Int):Element
		return <div class="flex flex-col gap-6">
			${SettingsParts.card("rayde-appearance-scheme", "Appearance", "Light, dark, or whichever your system is in.", [<div class="flex items-center gap-3">{schemeTiles()}</div>])}
			${SettingsParts.card("rayde-appearance-theme", "Theme", "Each theme has a light and a dark scheme. The pictures show the one in use.", [<div class="flex gap-4">{themeCards()}</div>])}
			${SettingsParts.card("rayde-appearance-custom", "Custom themes", "Theme bundles (.raytheme) installed in the user's .rayde/themes or the workspace's. One chosen here is used in place of the built-in themes above.", customThemes())}
			${SettingsParts.card("rayde-appearance-controls", "Window controls", "Close, minimize and maximize, drawn in the title bar. Platform default follows the operating system and, on Linux, the desktop.", [controlChoice()])}
		</div>;

	function controlChoice():Element {
		var items:Array<Element> = [for (s in WindowControls.styles) <select-item value={s.id}>${s.label}</select-item>];
		return <select id="rayde-window-controls-style" value={props.appearance.windowControls} size={Sm} class="rayde-control-wide" onChange={v -> pickControls(v)}>{items}</select>;
	}

	function pickControls(style:String):Void {
		if (props.appearance.windowControls == style)
			return;
		props.appearance.windowControls = style;
		props.appearance.save(props.root);
		revision.set(revision.get() + 1);
		props.onChanged();
	}

	function schemeTiles():Array<Element>
		return [
			schemeTile("system", "System", Icons.COMPUTER_LINE),
			schemeTile("light", "Light", Icons.SUN_LINE),
			schemeTile("dark", "Dark", Icons.MOON_LINE)
		];

	function schemeTile(id:String, label:String, icon:ashui.svg.SvgDocument):Element {
		var tile = <div id={"rayde-scheme-" + id} class="rayde-scheme flex items-center gap-2 px-4 cursor-pointer" height={40} onClick={_ -> pick(props.appearance.theme, id)}>
			<icon document={icon} class="size-4"/>
			<text class="text-sm">${label}</text>
		</div>;
		if (props.appearance.scheme == id)
			ashui.css.Identity.of(tile.tree, tile.node.id).setAttribute("data-on", "");
		return tile;
	}

	function themeCards():Array<Element>
		return [for (t in Appearance.themes) themeCard(t)];

	function themeCard(t:ThemeChoice):Element {
		var scheme = Theming.resolved(props.appearance), c = Theming.colors(t.id, scheme), on = props.appearance.theme == t.id;
		var card = <div id={"rayde-theme-" + t.id} class="rayde-theme-card flex flex-col gap-3 p-3 flex-1 min-w-0 cursor-pointer" onClick={_ -> pick(t.id, props.appearance.scheme)}>
			<div class="rayde-swatch flex shrink-0" height={104} bg={c.get(ColorToken.Background).toBrush()}>
				<div class="flex flex-col gap-2 p-2 shrink-0" width={56} bg={c.get(ColorToken.Surface).toBrush()}>
					${bar(.7, c.get(ColorToken.TextSecondary).withAlpha(.6))}
					${bar(.9, c.get(ColorToken.TextSecondary).withAlpha(.6))}
					${bar(.55, c.get(ColorToken.TextSecondary).withAlpha(.6))}
				</div>
				<div class="flex flex-col gap-2 p-3 flex-1">
					${bar(.5, c.get(ColorToken.TextPrimary))}
					${bar(.95, c.get(ColorToken.TextSecondary).withAlpha(.6))}
					${bar(.75, c.get(ColorToken.TextSecondary).withAlpha(.6))}
					<div class="flex-1"/>
					<div class="rayde-swatch-line shrink-0" widthPercent={.4} height={14} bg={c.get(ColorToken.Primary).toBrush()}/>
				</div>
			</div>
			<div class="flex items-center justify-between">
				<text class="text-sm font-semibold">${t.label}</text>
				<if {on}><icon document={Icons.CHECK_LINE} class="size-4 text-primary"/></if>
			</div>
			<text class="text-xs text-text-tertiary">${t.note}</text>
		</div>;
		if (on)
			ashui.css.Identity.of(card.tree, card.node.id).setAttribute("data-on", "");
		return card;
	}

	// Custom themes

	function customThemes():Array<Element> {
		var list = Themes.scan(props.root);
		var active = Lambda.find(list, t -> t.file.id == props.appearance.theme);
		var out:Array<Element> = [];
		if (list.length == 0)
			out.push(<text id="rayde-custom-theme-empty" class="text-xs text-text-tertiary">No custom themes installed. Install a .raytheme file or a folder with one below, or copy it into the themes folder.</text>);
		else {
			var items:Array<Element> = [<select-item value="">Built-in themes</select-item>];
			for (t in list)
				items.push(<select-item value={t.file.id}>${t.file.name + (t.file.version == "" ? "" : "  " + t.file.version)}</select-item>);
			out.push(SettingsParts.field("Installed", "Choosing one replaces the built-in theme in use", <select id="rayde-custom-theme" value={active == null ? "" : active.file.id} size={Sm} class="rayde-control-wide" onChange={v -> chooseCustom(v)}>{items}</select>));
		}
		if (active != null)
			out.push(customDetails(active));
		out.push(<div class="flex items-center gap-2">
			<input height={32} id="rayde-theme-path" value={themePath} placeholder="Path to a .raytheme file or a theme folder" class="rayde-control-wide" onKeyDown={e -> if (e.key.match(Named(Enter))) installTheme()}/>
			<button id="rayde-theme-install" variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> installTheme()}>Install</button>
			<if {active != null && active.scope == "User"}><button id="rayde-theme-remove" variant={Destructive} size={Sm} onClick={_ -> removeTheme(active.file.id)}>Remove</button></if>
		</div>);
		for (n in notes)
			out.push(<text class="text-xs text-text-secondary">${n}</text>);
		var folder = Themes.userDir();
		if (folder != null)
			out.push(<text class="text-xs text-text-tertiary">${"Themes folder: " + folder}</text>);
		return out;
	}

	/** What is known of the theme in use: its picture, who made it, and what is wrong with the file. */
	function customDetails(t:rayde.theme.Themes.InstalledTheme):Element {
		var f = t.file, scheme = Theming.resolved(props.appearance), c = Theming.colors(f.id, scheme);
		var card = <div id="rayde-custom-details" class="rayde-theme-card flex gap-4 p-3">
			<div class="rayde-swatch flex shrink-0" width={190} height={88} bg={c.get(ColorToken.Background).toBrush()}>
				<div class="flex flex-col gap-2 p-2 shrink-0" width={44} bg={c.get(ColorToken.Surface).toBrush()}>
					${bar(.7, c.get(ColorToken.TextSecondary).withAlpha(.6))}
					${bar(.9, c.get(ColorToken.TextSecondary).withAlpha(.6))}
				</div>
				<div class="flex flex-col gap-2 p-3 flex-1">
					${bar(.5, c.get(ColorToken.TextPrimary))}
					${bar(.9, c.get(ColorToken.TextSecondary).withAlpha(.6))}
					<div class="flex-1"/>
					<div class="rayde-swatch-line shrink-0" widthPercent={.4} height={12} bg={c.get(ColorToken.Primary).toBrush()}/>
				</div>
			</div>
			<div class="flex flex-col gap-1 flex-1 min-w-0">
				<text class="text-sm font-semibold">${f.name + (f.version == "" ? "" : "  " + f.version) + (f.author == "" ? "" : "  by " + f.author)}</text>
				<if {f.description != ""}><text class="text-xs text-text-secondary">${f.description}</text></if>
				<text class="text-xs text-text-tertiary">${"Extends " + f.base + ". " + t.scope + ": " + haxe.io.Path.withoutDirectory(t.path)}</text>
				{[for (p in f.problems) <text class="text-xs text-warning">${p}</text>]}
			</div>
		</div>;
		ashui.css.Identity.of(card.tree, card.node.id).setAttribute("data-on", "");
		return card;
	}

	/** Uses the theme the list chose, or goes back to a built-in one for "Built-in themes". */
	function chooseCustom(id:String):Void {
		var active = Lambda.find(Themes.installed(), t -> t.file.id == props.appearance.theme);
		if (id == "" && active == null)
			return;
		notes = [];
		pick(id == "" ? "restrained" : id, props.appearance.scheme);
	}

	function installTheme():Void {
		var source = StringTools.trim(themePath.get());
		if (source == "")
			return;
		var problems = [];
		var t = Themes.install(source, problems);
		if (t == null)
			notes = problems;
		else {
			themePath.set("");
			notes = ['Installed ${t.file.name}. Choose it in the list.'];
		}
		revision.set(revision.get() + 1);
	}

	function removeTheme(id:String):Void {
		var name = Lambda.find(Themes.installed(), t -> t.file.id == id);
		if (!Themes.remove(id))
			return;
		notes = ['Removed ${name == null ? id : name.file.name}.'];
		if (props.appearance.theme == id) {
			props.appearance.theme = "restrained";
			props.appearance.save(props.root);
			Theming.apply(props.appearance);
			props.onChanged();
		}
		revision.set(revision.get() + 1);
	}

	/** One line of the picture's text, a fraction of the width it has. */
	function bar(share:Float, color:ashui.theme.Rgba):Element
		return <div class="rayde-swatch-line shrink-0" widthPercent={share} height={6} bg={color.toBrush()}/>;

	/** Puts the choice on the window, writes it down, and draws the page again. */
	function pick(theme:String, scheme:String):Void {
		if (props.appearance.theme == theme && props.appearance.scheme == scheme)
			return;
		props.appearance.theme = theme;
		props.appearance.scheme = scheme;
		props.appearance.save(props.root);
		Theming.apply(props.appearance);
		revision.set(revision.get() + 1);
		props.onChanged();
	}

}
