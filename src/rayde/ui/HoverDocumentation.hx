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
				#if wasm
				var bridge = rayde.workspace.PageHost.bridge;
				if (bridge != null) {
					var data = Signal.make(({kind:"document",children:[{kind:"paragraph",children:[{kind:"text",text:"Loading documentation…"}]}]}:Dynamic));
					var view = new MarkdownView(data,(_, link) -> openLink(Std.string(link.href)),null,null,null,null,true);
					body.tree.addChild(body.node.id,view.node.id);
					var pending = bridge.requestAsync("page.markdown",{source:source}), closed = false;
					var receive:ashui.layout.LayoutTree->Void = null;
					receive = tree -> {
						if (closed || tree != body.tree || !pending.isReady()) return;
						ashui.layout.LayoutTree.flushHooks.remove(receive); ashui.core.Work.notify();
						try { var result = pending.await().result; if (result != null) data.set(result); }
						catch (_:Dynamic) data.set({kind:"document",children:[{kind:"paragraph",children:[{kind:"text",text:"Documentation could not be formatted."}]}]});
					};
					ashui.layout.LayoutTree.flushHooks.push(receive);
					ashui.reactive.Owner.onCleanup(() -> { closed = true; ashui.layout.LayoutTree.flushHooks.remove(receive); });
					if (remaining <= 0) break;
					continue;
				}
				#else
				var bytes = haxe.io.Bytes.ofString(source);
				try {
					var result = parseNative(bytes.getData(), bytes.length);
					if (result != null) parsed = haxe.Json.parse(result.sub(4, result.getI32(0)).toBytes(result.getI32(0)).toString());
				} catch (_:Dynamic) {}
				#end
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
		#if wasm
		if (rayde.workspace.PageHost.bridge != null) rayde.workspace.PageHost.bridge.notify("page.external",{url:href});
		#else
		switch Sys.systemName() {
			case "Mac": Sys.command("open", [href]);
			case "Windows": Sys.command("rundll32", ["url.dll,FileProtocolHandler", href]);
			case _: Sys.command("xdg-open", [href]);
		}
		#end
	}

	@:hlNative("rayscript", "markdown_fragment") static function parseNative(bytes:hl.Bytes, length:Int):hl.Bytes return null;
}
