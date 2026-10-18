package rayde.ui;

import ashui.components.Icon;
import ashui.components.Select;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.theme.ColorToken;
import ashui.ui.Component;
import rayde.settings.Appearance;
import rayde.settings.Appearance.ThemeChoice;

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

	function render():Element
		return SettingsParts.page("rayde-appearance", <div class="flex flex-col gap-6">
			${SettingsParts.header(Icons.PALETTE_LINE, "Color scheme", ".rayde/settings.json. A choice is applied to this window and written to the file at once.")}
			<for {r in [revision.get()]}>${sections(r)}</for>
		</div>);

	function sections(_:Int):Element
		return <div class="flex flex-col gap-6">
			${SettingsParts.card("rayde-appearance-scheme", "Appearance", "Light, dark, or whichever your system is in.", [<div class="flex items-center gap-3">{schemeTiles()}</div>])}
			${SettingsParts.card("rayde-appearance-theme", "Theme", "Each theme has a light and a dark scheme. The pictures show the one in use.", [<div class="flex gap-4">{themeCards()}</div>])}
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
