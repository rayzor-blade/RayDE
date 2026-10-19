package rayde.ui;

import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.theme.ColorScheme;
import ashui.ui.Component;
import rayde.theme.ThemeEdit;
import rayde.theme.ThemeFile;
import rayde.theme.ThemeStudio;

typedef ThemePaletteProps = {studio:ThemeStudio, scheme:ColorScheme};

/**
 * The colour tokens of the theme in the scheme being shown, in groups: each with its value, where the value comes
 * from, and an input that writes it to the scheme's `colors` in the file. Reset takes the file's value away.
 */
class ThemePalette extends Component<ThemePaletteProps> {
	static final groups = [
		{id: "brand", label: "Brand", tokens: ["primary", "primaryHover", "primaryActive", "secondary", "secondaryHover", "secondaryActive", "accent", "accentSubtle"]},
		{id: "status", label: "Status", tokens: ["success", "successBg", "warning", "warningBg", "error", "errorBg", "info", "infoBg"]},
		{id: "surfaces", label: "Surfaces", tokens: ["background", "surface", "surfaceElevated", "surfaceOverlay"]},
		{id: "text", label: "Text", tokens: ["textPrimary", "textSecondary", "textTertiary", "textInverse", "textLink"]},
		{id: "borders", label: "Borders", tokens: ["border", "borderSecondary", "borderHover", "borderFocus", "borderError"]},
		{id: "inputs", label: "Inputs", tokens: ["inputBg", "inputBgHover", "inputBgFocus", "inputBgDisabled"]},
		{id: "other", label: "Selection and tooltip", tokens: ["selection", "selectionText", "tooltipBg", "tooltipText"]}
	];

	final inputs = new Map<String, Signal<String>>();

	/** Why the last value typed was not taken, by token. */
	final refused = Signal.make("");

	function input(token:String):Signal<String> {
		var s = inputs.get(token);
		if (s == null)
			inputs.set(token, s = Signal.make(""));
		return s;
	}

	function render():Element
		return <div id="rayde-theme-palette" class="flex flex-col gap-5">
			<for {k in [{theme: props.studio.theme.get(), scheme: props.scheme, note: refused.get()}]}>${body(k.theme, k.scheme, k.note)}</for>
		</div>;

	function body(t:ThemeFile, scheme:ColorScheme, note:String):Element {
		var dark = scheme == Dark;
		var spec = dark ? t.dark : t.light;
		var colors = rayde.ui.Theming.bundleOf(t).forScheme(scheme).colors;
		var derived = ThemeFile.derive(spec.colors, dark);
		return <div class="flex flex-col gap-5">
			<if {note != ""}><text id="rayde-token-refused" class="text-xs text-warning">${note}</text></if>
			{[for (g in groups) tokenGroup(g.id, g.label, g.tokens, colors, spec.colors, derived, scheme)]}
		</div>;
	}

	function tokenGroup(id:String, label:String, tokens:Array<String>, colors:Dynamic, set:Map<String, rayde.theme.ThemeFile.Color>, derived:Map<String, rayde.theme.ThemeFile.Color>, scheme:ColorScheme):Element
		return <div id={"rayde-palette-" + id} class="flex flex-col gap-1">
			<text class="rayde-heading pb-1">${label}</text>
			{[for (token in tokens) row(token, Reflect.field(colors, token), set.exists(token) ? "set" : derived.exists(token) ? "derived" : "", scheme)]}
		</div>;

	function row(token:String, c:ashui.theme.Rgba, state:String, scheme:ColorScheme):Element {
		var hex = ThemeFile.toHex({r: c.r, g: c.g, b: c.b, a: c.a});
		input(token).set(hex);
		return <div id={"rayde-token-" + token} class="flex items-center gap-3" height={30}>
			<div class="rayde-token-swatch shrink-0" width={22} height={22} bg={c.toBrush()}/>
			<text class="text-xs text-text-secondary shrink-0" width={120}>${token}</text>
			<input height={28} id={"rayde-token-input-" + token} value={input(token)} class="rayde-control-narrow" onKeyDown={e -> if (e.key.match(Named(Enter))) commit(token, scheme)}/>
			<text class="text-xs text-text-tertiary shrink-0" width={52}>${state}</text>
			<if {state == "set"}>
				<tooltip label="Remove from the file" side="left">
					<button id={"rayde-token-reset-" + token} variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> reset(token, scheme)}><icon document={Icons.RESTART_LINE} class="size-4"/></button>
				</tooltip>
			</if>
		</div>;
	}

	static function sectionOf(scheme:ColorScheme):String
		return scheme == Dark ? "dark" : "light";

	/** The path the colour is written to: where the scheme's section already spells it, else `<scheme>.colors.<token>`. */
	function pathOf(token:String, scheme:ColorScheme):String {
		var head = sectionOf(scheme) + ".colors.";
		var own = Lambda.find(props.studio.colorPaths(token), p -> StringTools.startsWith(p, head));
		return own != null ? own : head + token;
	}

	function commit(token:String, scheme:ColorScheme):Void {
		var text = StringTools.trim(input(token).get());
		var c = ThemeFile.parseColor(text);
		if (c == null) {
			refused.set('$token: expected a colour such as #7c5cff, #7c5cff80 or rgba(124, 92, 255, 0.5)');
			return;
		}
		refused.set("");
		var path = pathOf(token, scheme);
		var why = props.studio.edit(t -> ThemeEdit.setText(t, path, ThemeFile.toHex(c)));
		if (why != null)
			refused.set(why);
	}

	/** Takes the colour out of the scheme's section; a value the file shares between schemes moves to the other scheme first. */
	function reset(token:String, scheme:ColorScheme):Void {
		var paths = props.studio.colorPaths(token);
		var t = props.studio.theme.get();
		var other = scheme == Dark ? "light" : "dark";
		var otherSpec = scheme == Dark ? t.light : t.dark;
		var shared = Lambda.filter(paths, p -> StringTools.startsWith(p, "colors."));
		var why = props.studio.edit(text -> {
			var out = text;
			var keep = otherSpec.colors.get(token);
			var theirs = other + ".colors.";
			if (shared.length > 0 && keep != null && !Lambda.exists(paths, p -> StringTools.startsWith(p, theirs)))
				out = ThemeEdit.setText(out, theirs + token, ThemeFile.toHex(keep));
			for (p in paths)
				if (StringTools.startsWith(p, sectionOf(scheme) + ".colors.") || StringTools.startsWith(p, "colors."))
					out = ThemeEdit.remove(out, p);
			out;
		});
		if (why != null)
			refused.set(why);
	}
}
