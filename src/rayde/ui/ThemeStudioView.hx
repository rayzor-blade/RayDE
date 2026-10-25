package rayde.ui;

import rayde.workspace.Fs;
import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Select;
import ashui.components.Toggle;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.theme.ColorScheme;
import ashui.ui.Component;
import rayde.settings.Appearance;
import rayde.theme.ThemeEdit;
import rayde.theme.ThemeFile;
import rayde.theme.Themes;
import rayde.theme.ThemeStudio;

using StringTools;

typedef ThemeStudioViewProps = {
	studio:ThemeStudio,
	appearance:Appearance,
	/** Bumped when the scheme changes outside this page, so it is drawn again. */
	revision:Signal<Int>,
	/** Switches the window to `light` or `dark`. */
	onScheme:String->Void,
	/** Opens the theme file as text, at the entry `at` (a path such as `dark.colors.primary`) when there is one. */
	onText:Null<String>->Void,
	/** Opens a file beside the theme. */
	onOpen:String->Void
};

/**
 * The page of a theme being written: its problems, then its identity, colours, type, shape and stylesheets as forms
 * that write to the file, and a gallery of components in the theme. The window wears the theme as it is typed, so
 * the page is the same theme it edits.
 */
class ThemeStudioView extends Component<ThemeStudioViewProps> {
	final name = Signal.make("");
	final version = Signal.make("");
	final author = Signal.make("");
	final description = Signal.make("");
	final id = Signal.make("");
	final numbers = new Map<String, Signal<String>>();
	final newCss = Signal.make("");
	final refused = Signal.make("");

	/** What installing the theme said: where it went, or why it did not. */
	final installNote = Signal.make("");

	function number(key:String):Signal<String> {
		var s = numbers.get(key);
		if (s == null)
			numbers.set(key, s = Signal.make(""));
		return s;
	}

	function scheme():ColorScheme
		return Theming.resolved(props.appearance);

	function render():Element {
		var studio = props.studio;
		return <div id="rayde-theme-studio" class="rayde-settings flex flex-1 min-h-0 justify-center overflow-auto">
			<div class="flex flex-col gap-6 px-8 py-8" width={780}>
				<for {k in [{scheme: props.revision.get(), theme: studio.theme.get(), stale: studio.stale.get(), note: installNote.get()}]}>${header(k.stale, k.note)}</for>
				<for {k in [studio.problems.get()]}>${problems(k)}</for>
				<for {k in [{scheme: props.revision.get(), theme: studio.theme.get()}]}>${sections()}</for>
				<div class="shrink-0" height={40}/>
			</div>
		</div>;
	}

	/** The forms and the preview, made again when the scheme changes so they show its values. */
	function sections():Element {
		var studio = props.studio;
		return <div class="flex flex-col gap-6">
			${SettingsParts.card("rayde-theme-identity", "Theme", "Identifier, metadata and the built-in theme it extends.", [identity()])}
			${SettingsParts.card("rayde-theme-colors", "Colors", "Tokens of the scheme in view. A value written here goes in that scheme's colors; reset removes it.", [<theme-palette studio={studio} scheme={scheme()}/>])}
			${SettingsParts.card("rayde-theme-type", "Typography", "Font family by role, text sizes and the font files the theme brings.", [<theme-typography studio={studio} scheme={scheme()}/>])}
			${SettingsParts.card("rayde-theme-shape", "Shape and spacing", "Corner radii in pixels, squircle smoothing and the spacing unit.", [shape()])}
			${SettingsParts.card("rayde-theme-css", "Stylesheets", "CSS applied while the theme is in use. Selectors are placed under the theme.", [stylesheets()])}
			${SettingsParts.card("rayde-theme-gallery", "Preview", "Components in the theme and scheme in use.", [<theme-gallery/>])}
		</div>;
	}

	// Header

	function header(stale:Bool, note:String):Element {
		var t = props.studio.theme.get(), light = scheme() == Light;
		return <div class="flex flex-col gap-2">
			<div class="flex items-center gap-4">
				<div class="rayde-tile flex items-center justify-center shrink-0" width={44} height={44}><icon document={Icons.PALETTE_LINE} class="size-5"/></div>
				<div class="flex flex-col gap-1 flex-1 min-w-0">
					<text id="rayde-theme-title" class="text-2xl font-semibold tracking-tighter truncate">${t.name}</text>
					<if {stale}><text id="rayde-theme-status" class="text-sm text-warning">Showing last valid theme</text>
					<else><text id="rayde-theme-status" class="text-sm text-text-secondary">${haxe.io.Path.withoutDirectory(t.file) + ", extends " + t.base}</text></if>
				</div>
				<div class="flex items-center gap-2 shrink-0">
					<toggle-group id="rayde-theme-scheme" type="single" variant={Outline} size={Sm} value={[light ? "light" : "dark"]} class="rayde-scheme-toggle" onValueChange={v -> if (v.length > 0) props.onScheme(v[0])}>
						<toggle-group-item id="rayde-theme-light" value="light">Light</toggle-group-item>
						<toggle-group-item id="rayde-theme-dark" value="dark">Dark</toggle-group-item>
					</toggle-group>
					<button id="rayde-theme-text" variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> props.onText(null)}><icon document={Icons.CODE_BOX_LINE} class="size-4"/>Open as JSON</button>
					<button id="rayde-theme-install" variant={Primary} size={Sm} class="rayde-add" onClick={_ -> install()}><icon document={Icons.DOWNLOAD_LINE} class="size-4"/>Install</button>
				</div>
			</div>
			<if {note != ""}><text id="rayde-theme-install-note" class="text-xs text-text-secondary">${note}</text></if>
		</div>;
	}

	function problems(list:Array<rayde.theme.ThemeFile.Problem>):Element {
		if (list.length == 0)
			return <div/>;
		return <div id="rayde-theme-problems" class="rayde-note flex flex-col gap-1 px-4 py-3">
			{[for (p in list) <div class="rayde-entry flex items-center gap-3 cursor-pointer" onClick={_ -> props.onText(p.at)}>
				<icon document={Icons.ALERT_LINE} class="size-4 shrink-0 text-warning"/>
				<text class="text-xs flex-1 min-w-0">${p.message}</text>
			</div>]}
		</div>;
	}

	// Fields

	function text(label:String, hint:String, id:String, value:Signal<String>, placeholder:String, path:String):Element
		return SettingsParts.field(label, hint, <input height={32} id={id} value={value} placeholder={placeholder} class="rayde-control-wide" onKeyDown={e -> if (e.key.match(Named(Enter))) saveText(path, value)}/>);

	function saveText(path:String, value:Signal<String>):Void {
		var v = value.get().trim();
		var why = props.studio.edit(t -> v == "" ? ThemeEdit.remove(t, path) : ThemeEdit.setText(t, path, v));
		refused.set(why == null ? "" : why);
	}

	function identity():Element {
		var t = props.studio.theme.get();
		id.set(t.id);
		name.set(t.name == t.id ? "" : t.name);
		version.set(t.version);
		author.set(t.author);
		description.set(t.description);
		var bases:Array<Element> = [for (b in ThemeFile.BASES) <select-item value={b}>${b}</select-item>];
		return <div class="flex flex-col gap-3">
			<if {refused.get() != ""}><text id="rayde-theme-refused" class="text-xs text-warning">${refused.get()}</text></if>
			${text("Id", "Name in the settings file; letters, digits, dots, dashes, underscores", "rayde-theme-id", id, "my-theme", "id")}
			${text("Name", "Display name", "rayde-theme-name", name, "My theme", "name")}
			${text("Version", "Semantic version", "rayde-theme-version", version, "1.0.0", "version")}
			${text("Author", "Shown in the theme list", "rayde-theme-author", author, "", "author")}
			${text("Description", "Short summary", "rayde-theme-description", description, "", "description")}
			${SettingsParts.field("Extends", "Built-in theme the tokens start from", <select id="rayde-theme-extends" value={t.base} size={Sm} class="rayde-control" onChange={v -> {
				var why = props.studio.edit(x -> ThemeEdit.setText(x, "extends", v));
				refused.set(why == null ? "" : why);
			}}>{bases}</select>)}
		</div>;
	}

	// Shape

	static function round(v:Float):String
		return Std.string(Math.round(v * 1000) / 1000);

	function shape():Element {
		var t = props.studio.theme.get();
		var bundle = Theming.bundleOf(t).forScheme(scheme());
		var rows:Array<Element> = [];
		for (step in ThemeFile.RADII) {
			var field = "radius" + step.charAt(0).toUpperCase() + step.substr(1);
			rows.push(numberField("radii." + step, step, Reflect.field(bundle.radii, field)));
		}
		var shapeRows:Array<Element> = [
			numberField("shape.smoothing", "smoothing", bundle.shape.cornerSmoothing),
			numberField("shape.exponent", "exponent", bundle.shape.cornerExponent),
			numberField("shape.threshold", "threshold", bundle.shape.smoothingThreshold),
			numberField("spacing.base", "spacing", bundle.spacing.space1)
		];
		return <div class="flex flex-col gap-4">
			<div class="flex flex-wrap gap-4">{rows}</div>
			<div class="flex flex-wrap gap-4">{shapeRows}</div>
			<div class="flex items-center gap-3">
				<for {k in [ThemeFile.RADII]}>${[for (step in k) radiusSample(step, bundle)]}</for>
			</div>
		</div>;
	}

	function radiusSample(step:String, bundle:ashui.theme.Theme):Element {
		var field = "radius" + step.charAt(0).toUpperCase() + step.substr(1);
		var radius:Float = Reflect.field(bundle.radii, field);
		return <div class="rayde-radius-sample shrink-0" width={36} height={36} cornerRadius={ashui.types.CornerRadius.all(Math.min(radius, 18))}/>;
	}

	function numberField(path:String, label:String, value:Float):Element {
		var s = number(path);
		s.set(round(value));
		return <div class="flex flex-col gap-1">
			<text class="text-xs text-text-tertiary">${label}</text>
			<input height={28} id={"rayde-theme-" + path.replace(".", "-")} value={s} class="rayde-number" onKeyDown={e -> if (e.key.match(Named(Enter))) saveNumber(path, s)}/>
		</div>;
	}

	function saveNumber(path:String, value:Signal<String>):Void {
		var v = value.get().trim();
		var n = Std.parseFloat(v);
		if (v != "" && Math.isNaN(n)) {
			refused.set(path + ": expected a number");
			return;
		}
		var why = props.studio.edit(t -> v == "" ? ThemeEdit.remove(t, path) : ThemeEdit.setNumber(t, path, n));
		refused.set(why == null ? "" : why);
	}

	// Stylesheets

	function stylesheets():Element {
		var t = props.studio.theme.get();
		var rows:Array<Element> = [];
		if (t.css.length == 0)
			rows.push(<text id="rayde-theme-no-css" class="text-xs text-text-tertiary">No stylesheet.</text>);
		for (s in t.css)
			rows.push(s.file != null
				? <div class="flex items-center gap-2">
					<icon document={Icons.FILE_TEXT_LINE} class="size-4 shrink-0 text-text-secondary"/>
					<text class="text-xs flex-1 min-w-0 truncate">${s.file}</text>
					<button variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> props.onOpen(s.file)}>Open</button>
				</div>
				: <div class="flex items-center gap-2">
					<icon document={Icons.BRACES_LINE} class="size-4 shrink-0 text-text-secondary"/>
					<text class="text-xs flex-1 min-w-0 truncate text-text-secondary">${"inline, " + s.text.length + " characters"}</text>
					<button variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> props.onText("css")}>Open as JSON</button>
				</div>);
		rows.push(<div class="flex items-center gap-2">
			<input height={32} id="rayde-theme-css-new" value={newCss} placeholder="theme.css" class="rayde-control-wide" onKeyDown={e -> if (e.key.match(Named(Enter))) addCss()}/>
			<button id="rayde-theme-css-add" variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> addCss()}>Add stylesheet</button>
		</div>);
		return <div class="flex flex-col gap-3">{rows}</div>;
	}

	/** Installs the theme as it is on disk into the user's themes, where Settings > Color scheme lists it. */
	function install():Void {
		var problems:Array<String> = [];
		var t = Themes.install(props.studio.file, problems);
		installNote.set(t != null ? "Installed to " + t.path : "Not installed: " + problems.length + (problems.length == 1 ? " problem" : " problems") + " in the theme.");
	}

	/** Adds a stylesheet beside the theme, creating it when it is not there. */
	function addCss():Void {
		var file = newCss.get().trim();
		if (file == "")
			return;
		if (haxe.io.Path.isAbsolute(file) || file.split("/").indexOf("..") >= 0 || !file.endsWith(".css")) {
			refused.set('Stylesheet "$file" must be a .css path beside the theme file.');
			return;
		}
		var full = haxe.io.Path.join([haxe.io.Path.directory(props.studio.file), file]);
		try {
			if (!Fs.exists(full)) {
				Themes.ensure(haxe.io.Path.directory(full));
				Fs.saveContent(full, "");
			}
		} catch (e:Dynamic) {
			refused.set('Cannot create $file: $e');
			return;
		}
		newCss.set("");
		var why = props.studio.edit(t -> ThemeEdit.addCss(t, file));
		refused.set(why == null ? "" : why);
	}
}
