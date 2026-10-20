package rayde.ui;

import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.css.Identity;
import ashui.ui.Div;
import ashui.ui.Text;
import rayde.ext.MarkdownView;
import rayde.lang.LspProtocol;

/** Small, owned Markdown fragments share the preview styles without a VM or editor instance. */
class HoverDocumentation {
	public static function render(contents:Dynamic):Element {
		var body = new Div({});
		Identity.of(body.tree, body.node.id).setClasses(["rayde-hover-docs"]);
		var remaining = 65536;
		for (part in LspProtocol.hoverParts(contents)) {
			var source = part.text.substr(0, remaining);
			remaining -= source.length;
			var parsed:Dynamic = null;
			if (part.markdown) {
				var bytes = haxe.io.Bytes.ofString(source);
				var result = parseNative(bytes.getData(), bytes.length);
				if (result != null) parsed = haxe.Json.parse(result.sub(4, result.getI32(0)).toBytes(result.getI32(0)).toString());
			}
			if (parsed != null) {
				var view = new MarkdownView(Signal.make(parsed), (_, data) -> openLink(Std.string(data.href)), null, null, null, null, true);
				body.tree.addChild(body.node.id, view.node.id);
			} else body.appendChild(new Text(source));
			if (remaining <= 0) break;
		}
		return body;
	}

	static function openLink(href:String):Void {
		if (!~/^(https?:\/\/|mailto:)/i.match(href)) return;
		switch Sys.systemName() {
			case "Mac": Sys.command("open", [href]);
			case "Windows": Sys.command("rundll32", ["url.dll,FileProtocolHandler", href]);
			case _: Sys.command("xdg-open", [href]);
		}
	}

	@:hlNative("rayscript", "markdown_fragment") static function parseNative(bytes:hl.Bytes, length:Int):hl.Bytes return null;
}
