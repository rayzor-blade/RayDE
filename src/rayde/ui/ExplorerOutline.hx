package rayde.ui;

import ashui.components.TreeView;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.reactive.Watch;
import ashui.ui.Component;
import rayde.lang.Display;
import rayde.lang.Outline;
import rayde.lang.Outline.OutlineSymbol;

typedef ExplorerOutlineProps = {
	display:Display,
	?languages:rayde.lang.LanguageServers,
	?revision:Void->Int,
	file:Void->String,
	text:String->String,
	onSelect:(String, Int, Int)->Void
};

class ExplorerOutline extends Component<ExplorerOutlineProps> {
	function render():Element {
		var symbols = Signal.make(([]:Array<OutlineSymbol>)), message = Signal.make("Open a Haxe file to view its outline");
		var job = new ExplorerJob(props.display.cwd);
		var shownFile:String = null;
		var serial = 0;
		var cancel:Void->Void = () -> {};
		ashui.reactive.Owner.onCleanup(() -> { serial++; cancel(); });
		new Watch(() -> {
			var file = props.file();
			return {file:file, text:file != null && (StringTools.endsWith(file.toLowerCase(), ".hx") || props.languages != null && props.languages.client(file) != null) ? props.text(file) : null, revision:props.revision == null ? 0 : props.revision()};
		}, value -> {
			job.cancel();
			serial++; cancel(); cancel = () -> {};
			if (shownFile != value.file) { symbols.set([]); shownFile = value.file; }
			if (value.text == null) { message.set("Open a Haxe file to view its outline"); return; }
			message.set(symbols.get().length == 0 ? "Loading outline…" : "");
			var client = props.languages == null ? null : props.languages.client(value.file);
			if (client != null) {
				if (!client.supports("documentSymbolProvider")) { message.set("Language server outline unavailable"); return; }
				props.languages.sync(value.file, value.text);
				var request = serial, scope = value.file + "#outline";
				cancel = () -> client.cancelScope(scope);
				client.request("textDocument/documentSymbol", {textDocument:{uri:rayde.lang.LspProtocol.uri(value.file)}}, result -> {
					if (request != serial) return;
					var found = rayde.lang.LspProtocol.outline(result);
					symbols.set(found); message.set(found.length == 0 ? "No symbols in this file" : "");
				}, scope);
				return;
			}
			job.run(props.display.server.haxe, Outline.arguments(props.display.args, value.file), (code, reply) -> {
				try {
					var found = Outline.parse(reply);
					symbols.set(found); message.set(found.length == 0 ? "No symbols in this file" : "");
				} catch (_:Dynamic) message.set(symbols.get().length == 0 ? "Outline unavailable. Check this file for syntax errors." : "Showing the last outline until syntax errors are fixed.");
			}, value.text);
		}, (before, after) -> before.file == after.file && before.text == after.text && before.revision == after.revision);
		return <div id="rayde-outline-scroll" class="flex flex-col flex-1 min-h-0 overflow-auto">
			<if {message.get() != ""}><div class="px-3 py-2"><text class="text-xs text-text-secondary">${message.get()}</text></div></if>
			<for {items in [symbols.get()]}><tree-view id="rayde-outline-tree" onSelect={value -> { var pieces = value.split(":"); var character = Std.parseInt(pieces.pop()), line = Std.parseInt(pieces.pop()); props.onSelect(pieces.join(":"), line, character); }}>{[for (s in items) row(s, props.file())]}</tree-view></for>
		</div>;
	}

	function row(s:OutlineSymbol, file:String):Element {
		var kind = switch s.kind {
			case 1 | 5: "class";
			case 2 | 3 | 4 | 12 | 13 | 14: "type";
			case 8 | 9 | 10: "method";
			case 6 | 7 | 15 | 16: "field";
			case 17: "namespace";
			case _: "variable";
		};
		var icon = switch kind {
			case "class": Icons.BOX_2_LINE;
			case "type": Icons.T_BOX_LINE;
			case "method": Icons.CODE_BLOCK;
			case "namespace": Icons.NODE_TREE;
			case _: Icons.INSTANCE_LINE;
		};
		var item = <tree-item value={file + ":" + s.range.start.line + ":" + s.range.start.character} label={s.name} icon={icon} expanded={true}>{[for (child in s.children) row(child, file)]}</tree-item>;
		ashui.css.Identity.of(item.tree, item.node.id).setAttribute("data-symbol-kind", kind);
		return item;
	}
}
