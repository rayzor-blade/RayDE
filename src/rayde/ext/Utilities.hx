package rayde.ext;

/**
 * The utility classes an extension's markup can use in the Preview (`flex`, `gap-2`, `px-4`, `text-sm`,
 * `bg-surface`), as a stylesheet. ashui turns a `class="..."` of Tailwind-style utilities into properties
 * while a program is compiled; a view built while the extension runs has no compile, so RayDE gives the
 * classes a stylesheet instead. Each rule is under `.rds`, the Preview's root, so it reaches nothing else.
 * The colours are the theme's own tokens, so a switch between light and dark restyles the Preview too.
 */
class Utilities {
	/** The class the Preview's root carries. */
	public static inline var SCOPE = "rds";

	static final SPACING:Array<String> = ["0", "0.5", "1", "1.5", "2", "2.5", "3", "3.5", "4", "5", "6", "7", "8", "9", "10", "11", "12", "14", "16", "20", "24", "28", "32", "36", "40", "44", "48", "52", "56", "60", "64", "72", "80", "96"];

	static final COLORS = ["primary", "primary-hover", "primary-active", "secondary", "secondary-hover", "secondary-active", "success", "success-bg", "warning", "warning-bg", "error", "error-bg", "info", "info-bg", "background", "surface", "surface-elevated", "surface-overlay", "text-primary", "text-secondary", "text-tertiary", "text-inverse", "text-link", "border", "border-secondary", "border-hover", "border-focus", "border-error", "input-bg", "accent", "accent-subtle"];

	static var installed:Null<ashui.css.Stylesheet>;

	/** Puts the utilities in force, once; the problems the stylesheet's parse found, none unless this file is wrong. */
	public static function install():Array<String> {
		if (installed == null)
			installed = ashui.css.Css.load(css(), "extension studio utilities");
		return [for (d in installed.diagnostics) Std.string(d)];
	}

	static function px(n:String):String {
		var v = Std.parseFloat(n) * 4;
		return v == 0 ? "0" : (v == Math.floor(v) ? Std.string(Std.int(v)) : Std.string(v)) + "px";
	}

	static function esc(name:String):String
		return StringTools.replace(StringTools.replace(name, ".", "\\."), "/", "\\/");

	public static function css():String {
		var out = new StringBuf();
		function rule(name:String, body:String):Void
			out.add('.$SCOPE .${esc(name)} { $body }\n');
		out.add('.$SCOPE { color: var(--text-primary); font-size: 14px; }\n');
		out.add('.$SCOPE-root { display: flex; flex-direction: column; flex: 1 1 0%; min-height: 0; min-width: 0; }\n');
		for (d in ["flex", "block", "grid"])
			rule(d, 'display: $d');
		rule("hidden", "display: none");
		rule("flex-row", "flex-direction: row");
		rule("flex-col", "flex-direction: column");
		rule("flex-wrap", "flex-wrap: wrap");
		rule("flex-nowrap", "flex-wrap: nowrap");
		rule("flex-1", "flex: 1 1 0%");
		rule("flex-auto", "flex: 1 1 auto");
		rule("flex-none", "flex: none");
		rule("grow", "flex-grow: 1");
		rule("shrink", "flex-shrink: 1");
		rule("shrink-0", "flex-shrink: 0");
		for (a in ["start", "end", "center", "stretch", "baseline"]) {
			var value = a == "start" || a == "end" ? "flex-" + a : a;
			rule("items-" + a, "align-items: " + value);
			rule("self-" + a, "align-self: " + value);
		}
		for (j in [["start", "flex-start"], ["end", "flex-end"], ["center", "center"], ["between", "space-between"], ["around", "space-around"], ["evenly", "space-evenly"]])
			rule("justify-" + j[0], "justify-content: " + j[1]);

		for (n in SPACING) {
			var v = px(n);
			rule("gap-" + n, 'gap: $v');
			rule("gap-x-" + n, 'column-gap: $v');
			rule("gap-y-" + n, 'row-gap: $v');
			rule("p-" + n, 'padding: $v');
			rule("px-" + n, 'padding-left: $v; padding-right: $v');
			rule("py-" + n, 'padding-top: $v; padding-bottom: $v');
			for (side in [["t", "top"], ["r", "right"], ["b", "bottom"], ["l", "left"]]) {
				rule('p${side[0]}-$n', 'padding-${side[1]}: $v');
				rule('m${side[0]}-$n', 'margin-${side[1]}: $v');
			}
			rule("m-" + n, 'margin: $v');
			rule("mx-" + n, 'margin-left: $v; margin-right: $v');
			rule("my-" + n, 'margin-top: $v; margin-bottom: $v');
			rule("w-" + n, 'width: $v');
			rule("h-" + n, 'height: $v');
			rule("size-" + n, 'width: $v; height: $v');
			rule("min-w-" + n, 'min-width: $v');
			rule("min-h-" + n, 'min-height: $v');
		}
		rule("mx-auto", "margin-left: auto; margin-right: auto");
		rule("w-full", "width: 100%");
		rule("h-full", "height: 100%");
		rule("w-1/2", "width: 50%");
		rule("w-1/3", "width: 33.333%");
		rule("w-2/3", "width: 66.667%");
		rule("min-w-0", "min-width: 0");
		rule("min-h-0", "min-height: 0");
		rule("max-w-full", "max-width: 100%");

		var sizes = [["xs", "12", "16"], ["sm", "14", "20"], ["base", "16", "24"], ["lg", "18", "28"], ["xl", "20", "28"], ["2xl", "24", "32"], ["3xl", "30", "36"], ["4xl", "36", "40"]];
		for (s in sizes)
			rule("text-" + s[0], 'font-size: ${s[1]}px; line-height: ${s[2]}px');
		for (w in [["thin", "100"], ["light", "300"], ["normal", "400"], ["medium", "500"], ["semibold", "600"], ["bold", "700"], ["extrabold", "800"]])
			rule("font-" + w[0], "font-weight: " + w[1]);
		rule("italic", "font-style: italic");
		rule("underline", "text-decoration: underline");
		rule("line-through", "text-decoration: line-through");
		rule("uppercase", "text-transform: uppercase");
		for (a in ["left", "center", "right"])
			rule("text-" + a, "text-align: " + a);
		for (l in [["none", "1"], ["tight", "1.25"], ["snug", "1.375"], ["normal", "1.5"], ["relaxed", "1.625"]])
			rule("leading-" + l[0], "line-height: " + l[1]);
		rule("truncate", "overflow: hidden; text-overflow: ellipsis; white-space: nowrap");

		for (r in ["none", "sm", "md", "lg", "xl", "2xl", "3xl", "full"])
			rule("rounded-" + r, 'border-radius: var(--radius-$r)');
		rule("rounded", "border-radius: var(--radius-default)");
		rule("border", "border: 1px solid var(--border)");
		rule("border-0", "border-width: 0");
		rule("border-2", "border-width: 2px; border-style: solid");
		for (side in [["t", "top"], ["r", "right"], ["b", "bottom"], ["l", "left"]])
			rule("border-" + side[0], 'border-${side[1]}: 1px solid var(--border)');
		for (c in COLORS) {
			rule("bg-" + c, 'background: var(--$c)');
			rule("text-" + c, 'color: var(--$c)');
			rule("border-" + c, 'border-color: var(--$c)');
		}
		for (o in [0, 5, 10, 20, 25, 30, 40, 50, 60, 70, 75, 80, 90, 95, 100])
			rule("opacity-" + o, "opacity: " + o / 100);
		rule("overflow-hidden", "overflow: hidden");
		rule("overflow-auto", "overflow: auto");
		rule("overflow-scroll", "overflow: scroll");
		rule("relative", "position: relative");
		rule("absolute", "position: absolute");
		rule("inset-0", "top: 0; right: 0; bottom: 0; left: 0");
		return out.toString();
	}
}
