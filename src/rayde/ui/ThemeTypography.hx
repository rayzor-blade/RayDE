package rayde.ui;

import rayde.workspace.Fs;
import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.theme.FontName;
import rayde.theme.ThemeEdit;
import rayde.theme.ThemeFile;
import rayde.theme.ThemeStudio;
import rayde.theme.Themes;

using StringTools;

typedef ThemeTypographyProps = {studio:ThemeStudio, scheme:ashui.theme.ColorScheme};

/**
 * The type of a theme: the family of each role (`sans`, `serif`, `mono`) with a specimen set in it, the text sizes,
 * and the font files the theme brings. A file is copied beside the theme when it comes from elsewhere, and listed in
 * `fonts` under the family its faces carry.
 */
class ThemeTypography extends Component<ThemeTypographyProps> {
	static final sample = "Sphinx of black quartz, judge my vow 0123456789";

	final fields = new Map<String, Signal<String>>();
	final fontPath = Signal.make("");
	final fontFamily = Signal.make("");
	final refused = Signal.make("");

	function field(key:String):Signal<String> {
		var s = fields.get(key);
		if (s == null)
			fields.set(key, s = Signal.make(""));
		return s;
	}

	function render():Element
		return <div id="rayde-theme-typography" class="flex flex-col gap-5">
			<for {k in [{theme: props.studio.theme.get(), note: refused.get()}]}>${body(k.theme, k.note)}</for>
		</div>;

	function body(t:ThemeFile, note:String):Element {
		var type = Theming.bundleOf(t).forScheme(props.scheme).typography;
		return <div class="flex flex-col gap-5">
			<if {note != ""}><text id="rayde-font-refused" class="text-xs text-warning">${note}</text></if>
			<div class="flex flex-col gap-3">
				${role("sans", type.fontSans.name)}
				${role("serif", type.fontSerif.name)}
				${role("mono", type.fontMono.name)}
			</div>
			<div class="flex flex-col gap-1">
				<text class="rayde-heading pb-1">Sizes</text>
				<div class="flex flex-wrap gap-4">{[for (step in ThemeFile.SIZES) size(step, Reflect.field(type, "text" + step.charAt(0).toUpperCase() + step.substr(1)))]}</div>
			</div>
			<div id="rayde-theme-fonts" class="flex flex-col gap-2">
				<text class="rayde-heading pb-1">Font files</text>
				${fonts(t, type)}
			</div>
		</div>;
	}

	function role(name:String, family:String):Element {
		var s = field("role." + name);
		s.set(family);
		var specimen = switch name {
			case "serif": <text id="rayde-specimen-serif" class="rayde-font-serif text-base">${sample}</text>;
			case "mono": <text id="rayde-specimen-mono" class="rayde-font-mono text-base">${sample}</text>;
			case _: <text id="rayde-specimen-sans" class="rayde-font-sans text-base">${sample}</text>;
		}
		return <div class="flex flex-col gap-1">
			<div class="flex items-center gap-3">
				<text class="text-xs text-text-secondary shrink-0" width={44}>${name}</text>
				<input height={28} id={"rayde-font-" + name} value={s} class="rayde-control-wide" onKeyDown={e -> if (e.key.match(Named(Enter))) setRole(name, s.get())}/>
			</div>
			<div class="pl-14">${specimen}</div>
		</div>;
	}

	function setRole(role:String, family:String):Void {
		var v = family.trim();
		var why = props.studio.edit(t -> v == "" ? ThemeEdit.remove(t, "typography." + role) : ThemeEdit.setText(t, "typography." + role, v));
		refused.set(why == null ? "" : why);
	}

	function size(step:String, value:Float):Element {
		var s = field("size." + step);
		s.set(Std.string(Math.round(value * 100) / 100));
		return <div class="flex flex-col gap-1">
			<text class="text-xs text-text-tertiary">${step}</text>
			<input height={28} id={"rayde-font-size-" + step} value={s} class="rayde-number" onKeyDown={e -> if (e.key.match(Named(Enter))) setSize(step, s.get())}/>
		</div>;
	}

	function setSize(step:String, text:String):Void {
		var v = text.trim(), n = Std.parseFloat(v);
		if (v != "" && Math.isNaN(n)) {
			refused.set("sizes." + step + ": expected a number");
			return;
		}
		var why = props.studio.edit(t -> v == "" ? ThemeEdit.remove(t, "typography.sizes." + step) : ThemeEdit.setNumber(t, "typography.sizes." + step, n));
		refused.set(why == null ? "" : why);
	}

	// Font files

	function fonts(t:ThemeFile, type:ashui.theme.TypographyTokens):Element {
		var dir = haxe.io.Path.directory(t.file);
		var rows:Array<Element> = [];
		if (t.fonts.length == 0)
			rows.push(<text id="rayde-no-fonts" class="text-xs text-text-tertiary">No font files.</text>);
		for (f in t.fonts) {
			var used = [for (r in [{n: "sans", f: type.fontSans.name}, {n: "serif", f: type.fontSerif.name}, {n: "mono", f: type.fontMono.name}]) if (r.f == f.family) r.n];
			rows.push(<div class="flex flex-col gap-1">
				<div class="flex items-center gap-2">
					<text class="text-sm font-semibold flex-1 min-w-0 truncate">${f.family}</text>
					{[for (r in ["sans", "serif", "mono"]) chip(r, f.family, used.indexOf(r) >= 0)]}
				</div>
				{[for (name in f.files) fileRow(dir, name)]}
			</div>);
		}
		rows.push(<div class="flex items-center gap-2 pt-1">
			<input height={32} id="rayde-font-path" value={fontPath} placeholder="Font file (.ttf, .otf, .ttc, .woff2)" class="rayde-control-wide" onKeyDown={e -> if (e.key.match(Named(Enter))) addFont(dir)}/>
			<input height={32} id="rayde-font-family" value={fontFamily} placeholder="Family (from the file)" class="rayde-control-narrow" onKeyDown={e -> if (e.key.match(Named(Enter))) addFont(dir)}/>
			<button id="rayde-font-add" variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> addFont(dir)}>Add font</button>
		</div>);
		return <div class="flex flex-col gap-3">{rows}</div>;
	}

	function chip(role:String, family:String, on:Bool):Element {
		var c = <div id={"rayde-font-use-" + role + "-" + family.replace(" ", "-")} class="rayde-role-chip flex items-center px-2 shrink-0" height={22} onClick={_ -> setRole(role, family)}>
			<text class="text-xs">${role}</text>
		</div>;
		if (on)
			ashui.css.Identity.of(c.tree, c.node.id).setAttribute("data-on", "");
		return c;
	}

	function fileRow(dir:String, name:String):Element {
		var present = Fs.exists(haxe.io.Path.join([dir, name]));
		return <div class="flex items-center gap-2 pl-3">
			<if {present}><icon document={Icons.CHECK_LINE} class="size-4 shrink-0 text-success"/>
			<else><icon document={Icons.ERROR_WARNING_LINE} class="size-4 shrink-0 text-warning"/></if>
			<text class="text-xs flex-1 min-w-0 truncate text-text-secondary">${name}</text>
			<tooltip label="Remove from the theme" side="left">
				<button id={"rayde-font-remove-" + haxe.io.Path.withoutDirectory(name).replace(".", "-")} variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> removeFont(name)}><icon document={Icons.CLOSE_LINE} class="size-4"/></button>
			</tooltip>
		</div>;
	}

	function removeFont(name:String):Void {
		var why = props.studio.edit(t -> ThemeEdit.removeFont(t, name));
		refused.set(why == null ? "" : why);
	}

	/** Brings the file named in the path field into the theme, under `family` or the family its faces carry. */
	function addFont(dir:String):Void {
		var given = fontPath.get().trim();
		if (given == "")
			return;
		var source = haxe.io.Path.isAbsolute(given) ? given : haxe.io.Path.join([dir, given]);
		if (!Fs.exists(source) || Fs.isDirectory(source)) {
			refused.set('Nothing at $source.');
			return;
		}
		if (!FontName.isFontFile(source)) {
			refused.set("A font file is .ttf, .otf, .ttc or .woff2.");
			return;
		}
		var bytes = Fs.getBytes(source);
		var carried = FontName.of(bytes);
		var family = fontFamily.get().trim();
		if (family == "")
			family = carried != null ? carried[0] : "";
		if (family == "") {
			refused.set("The family of a .woff2 file cannot be read; enter it.");
			return;
		}
		var inside = StringTools.startsWith(haxe.io.Path.normalize(source), haxe.io.Path.addTrailingSlash(haxe.io.Path.normalize(dir)));
		var relative = inside ? haxe.io.Path.normalize(source).substr(haxe.io.Path.addTrailingSlash(haxe.io.Path.normalize(dir)).length) : "fonts/" + haxe.io.Path.withoutDirectory(source);
		try {
			if (!inside) {
				Themes.ensure(haxe.io.Path.join([dir, "fonts"]));
				Fs.saveBytes(haxe.io.Path.join([dir, relative]), bytes);
			}
		} catch (e:Dynamic) {
			refused.set('Cannot copy $given: $e');
			return;
		}
		fontPath.set("");
		fontFamily.set("");
		var why = props.studio.edit(t -> ThemeEdit.addFont(t, family, relative));
		refused.set(why == null ? "" : why);
	}
}
