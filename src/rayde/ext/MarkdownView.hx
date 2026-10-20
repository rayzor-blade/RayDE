package rayde.ext;

import ashui.components.CodeView;
import ashui.components.code.CodeHighlighter;
import ashui.css.Identity;
import ashui.input.Interaction;
import ashui.layout.Element;
import ashui.layout.Node;
import ashui.layout.Prop;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.reactive.Watch;
import ashui.svg.SvgDocument;
import ashui.theme.ThemeState;
import ashui.ui.Div;
import ashui.ui.Text;

/** A document owns its text, code viewers and vector images; replacing or hiding it releases them together. */
class MarkdownView {
	public final node:Node;
	public var diagrams(default, null):Array<ashui.canvaskit.CanvasKit> = [];
	final document:Signal<Dynamic>;
	final emit:(String, Dynamic)->Void;
	var child:Owner;
	var headings:Map<String, Node> = [];
	static final drawings:Map<Int, {document:SvgDocument, uses:Int}> = [];

	public function new(document:Signal<Dynamic>, emit:(String, Dynamic)->Void) {
		this.document = document;
		this.emit = emit;
		var body = box("rayde-markdown");
		node = body.node;
		new Watch(() -> { ThemeState.get().revision.get(); return {data:document.get(), scheme:ThemeState.get().scheme()}; }, value -> {
			var data = value.data;
			if (child != null) child.dispose();
			diagrams = [];
			headings = [];
			child = new Owner(body.tree);
			child.run(() -> {
				if (data != null) for (block in children(data)) body.appendChild(render(block));
			});
		}, (a, b) -> a.data == b.data && a.scheme == b.scheme);
		Owner.onCleanup(() -> { if (child != null) child.dispose(); headings.clear(); diagrams = []; });
	}

	static function box(classes:String):Div {
		var element = new Div({});
		Identity.of(element.tree, element.node.id).setClasses(classes.split(" "));
		return element;
	}

	static function children(data:Dynamic):Array<Dynamic>
		return data.children == null ? [] : data.children;

	static function text(data:Dynamic):String {
		if (data.text != null) return Std.string(data.text);
		return [for (part in children(data)) text(part)].join("");
	}

	function render(data:Dynamic):Element {
		var kind:String = data.kind;
		if (kind == "code") {
			var frame = box("rayde-md-code");
			frame.appendChild(new Text(data.language == "" ? "Plain text" : Std.string(data.language)));
			var viewer = new CodeView({value:Std.string(data.text), highlighter:rayde.ui.TextMateSyntax.fromTokens(data.tokens),
				lineNumbers:false, folding:false, minimap:false, indentGuides:false, highlightBrackets:false});
			viewer.node.set(Prop.Height, (Math.min(360, Math.max(44, Std.string(data.text).split("\n").length * 21 + 20)):Single));
			frame.appendChild(viewer);
			return frame;
		}
		if (kind == "math" || kind == "diagram") return drawing(data);
		if (kind == "error") {
			var error = box("rayde-md-error");
			error.appendChild(new Text(Std.string(data.text)));
			if (data.source != null) error.appendChild(new Text(Std.string(data.source)));
			return error;
		}
		if (kind == "image") {
			if (data.svgBytes != null) try return drawing({kind:"diagram", svg:haxe.crypto.Base64.decode(data.svgBytes).toString()}) catch (_:Dynamic) {}
			if (data.imageBytes != null) {
				try {
					var bitmap = ashui.types.Bitmap.fromBytes(haxe.crypto.Base64.decode(data.imageBytes));
					bitmap.shrink(2048);
					Owner.onCleanup(bitmap.dispose);
					var frame = box("rayde-md-drawing"), scale = Math.min(1., 700 / Math.max(1, bitmap.width));
					frame.appendChild(new ashui.ui.Image(bitmap, {width:(bitmap.width*scale:Single), height:(bitmap.height*scale:Single)}));
					return frame;
				} catch (_:Dynamic) {}
			}
			var fallback = box("rayde-md-image-alt");
			fallback.appendChild(new Text("Image: " + text(data) + (data.imageError == null ? "" : " — " + data.imageError)));
			return fallback;
		}
		if (["text", "em", "strong", "strike", "link", "inline-code", "task"].indexOf(kind) >= 0) {
			var line = box("rayde-md-paragraph");
			inlinePart(line, data, [], null);
			ashui.text.InlineFlow.attach(line);
			return line;
		}
		var classes = switch kind {
			case "heading": "rayde-md-heading rayde-md-h" + data.level;
			case "paragraph", "html": "rayde-md-paragraph";
			case "quote": "rayde-md-quote";
			case "list": "rayde-md-list";
			case "item": "rayde-md-item";
			case "table": "rayde-md-table";
			case "table-row", "table-head": "rayde-md-table-row" + (kind == "table-head" ? " rayde-md-table-head" : "");
			case "table-cell": "rayde-md-table-cell";
			case "rule": "rayde-md-rule";
			case "footnote": "rayde-md-footnote";
			case _: "rayde-md-paragraph";
		};
		var container = box(classes);
		if (kind == "heading" || kind == "footnote") {
			var id = (kind == "footnote" ? "footnote-" : "") + Std.string(data.id);
			headings.set(id, container.node);
			Identity.of(container.tree, container.node.id).setAttribute("data-md-heading", id);
		}
		if (["heading", "paragraph", "html", "table-cell"].indexOf(kind) >= 0) {
			for (part in children(data)) inlinePart(container, part, [], null);
			ashui.text.InlineFlow.attach(container);
		} else if (kind == "list") {
			var index:Int = data.start == null ? 0 : Std.int(data.start);
			for (item in children(data)) {
				var row = box("rayde-md-list-row"), content = box("rayde-md-list-content");
				if (!Lambda.exists(children(item), part -> part.kind == "task")) row.appendChild(new Text(data.start == null ? "•" : (index++) + "."));
				var line:Div = null;
				for (part in children(item)) {
					if (["text", "em", "strong", "strike", "link", "inline-code", "task"].indexOf(part.kind) >= 0) {
						if (line == null) { line = box("rayde-md-paragraph"); content.appendChild(line); ashui.text.InlineFlow.attach(line); }
						inlinePart(line, part, [], null);
					} else { line = null; content.appendChild(render(part)); }
				}
				row.appendChild(content); container.appendChild(row);
			}
		} else {
			if (kind == "table") for (row in children(data)) {
				var cells = children(row), align:Array<String> = data.align;
				for (i in 0...cells.length) if (align != null && i < align.length) cells[i].align = align[i];
			}
			for (part in children(data)) {
				if (["text", "em", "strong", "strike", "link", "inline-code", "task"].indexOf(part.kind) >= 0)
					inlinePart(container, part, [], null);
				else container.appendChild(render(part));
			}
		}
		if (kind == "table-cell") {
			if (data.align == "Right") container.node.set(Prop.TextAlign, ashui.types.Style.TextAlign.Right);
			if (data.align == "Center") container.node.set(Prop.TextAlign, ashui.types.Style.TextAlign.Center);
		}
		return container;
	}

	function inlinePart(parent:Div, data:Dynamic, styles:Array<String>, href:Null<String>):Void {
		var kind:String = data.kind;
		if (kind == "task") {
			var marker = box("rayde-md-task");
			Identity.of(marker.tree, marker.node.id).types.remove("div");
			Identity.register(marker.tree, marker.node, "span");
			marker.appendChild(new ashui.components.Checkbox({checked:data.checked == true, disabled:true, size:Sm}));
			parent.appendChild(marker);
			return;
		}
		if (kind == "math" || kind == "diagram" || kind == "error" || kind == "image") { parent.appendChild(render(data)); return; }
		if (kind == "break") {
			var line = box("rayde-md-break"); Identity.register(line.tree, line.node, "br"); parent.appendChild(line); return;
		}
		var next = styles.copy();
		switch kind {
			case "strong": next.push("rayde-md-strong");
			case "em": next.push("rayde-md-em");
			case "strike": next.push("rayde-md-strike");
			case "inline-code": next.push("rayde-md-inline-code");
			case "link": href = Std.string(data.href); next.push("rayde-md-link");
			case _:
		}
		if (data.text == null) {
			for (part in children(data)) inlinePart(parent, part, next, href);
			return;
		}
		var source = Std.string(data.text);
		if (source != "") {
			var word = box(["rayde-md-word"].concat(next).join(" "));
			Identity.of(word.tree, word.node.id).types.remove("div");
			Identity.register(word.tree, word.node, "span");
			word.appendChild(new Text(source));
			if (href != null) {
				var target = href;
				Interaction.of(word.node).onClick(_ -> {
					if (StringTools.startsWith(target, "#")) reveal(target.substr(1));
					else emit("link", {href:target});
				});
				Identity.of(word.tree, word.node.id).setAttribute("data-md-link", target);
			}
			parent.appendChild(word);
		}
	}

	function drawing(data:Dynamic):Element {
		var markup:String = data.kind == "diagram" && ThemeState.get().scheme() == Dark && data.darkSvg != null ? data.darkSvg : data.svg;
		var doc = acquire(markup);
		Owner.onCleanup(() -> release(doc));
		if (data.kind == "diagram" && data.text != null) return diagram(doc);
		var frame = box(data.kind == "math" && data.display != true ? "rayde-md-math-inline" : "rayde-md-drawing");
		if (data.kind == "math" && data.display != true) {
			Identity.of(frame.tree, frame.node.id).types.remove("div");
			Identity.register(frame.tree, frame.node, "span");
		}
		var scale = Math.min(1., 740 / Math.max(1, doc.width));
		var picture = new ashui.ui.Svg(doc, {width:(doc.width * scale:Single), height:(doc.height * scale:Single)});
		frame.appendChild(picture);
		Identity.of(frame.tree, frame.node.id).setAttribute("data-md-render", Std.string(data.kind));
		return frame;
	}

	function diagram(doc:SvgDocument):Element {
		var frame = box("rayde-md-diagram"), toolbar = box("rayde-md-diagram-tools"), area = box("rayde-md-diagram-viewport");
		Identity.of(frame.tree, frame.node.id).setAttribute("data-md-render", "diagram");
		var view = new ashui.canvaskit.Viewport2D();
		var picture = new ashui.ui.Svg(doc, {width:(doc.width:Single), height:(doc.height:Single)});
		picture.node.set(Prop.Position, ashui.types.Style.Position.Absolute);
		picture.node.set(Prop.Left, (0:Single)); picture.node.set(Prop.Top, (0:Single));
		picture.node.set(Prop.PointerEvents, ashui.types.Style.PointerEvents.None);
		area.appendChild(picture);
		var kit = new ashui.canvaskit.CanvasKit({viewport:view, background:new ashui.canvaskit.Background2D(None)});
		kit.momentumDecay = 0;
		kit.node.set(Prop.Position, ashui.types.Style.Position.Absolute);
		kit.node.set(Prop.Left, (0:Single)); kit.node.set(Prop.Top, (0:Single));
		kit.node.set(Prop.WidthPercent, (1:Single)); kit.node.set(Prop.HeightPercent, (1:Single));
		Identity.of(kit.tree, kit.node.id).addClasses(["rayde-md-mermaid-canvas"]);
		area.appendChild(kit); diagrams.push(kit);
		new Watch(() -> ({x:view.panX.get(), y:view.panY.get(), zoom:view.zoom.get()}), state -> {
			picture.node.set(Prop.Transform, new ashui.types.Transform(state.x*state.zoom + (state.zoom-1)*doc.width/2,
				state.y*state.zoom + (state.zoom-1)*doc.height/2, 0, state.zoom, state.zoom));
		});
		function fit():Void {
			var bounds = frame.tree.getBounds(area.node);
			if (bounds != null && bounds.width > 0 && bounds.height > 0) view.fit(0,0,doc.width,doc.height,bounds.width,bounds.height,0,.06);
		}
		function zoom(factor:Float):Void {
			var bounds = frame.tree.getBounds(area.node);
			if (bounds != null) view.zoomAt(bounds.width/2,bounds.height/2,factor);
		}
		function action(label:String, icon:SvgDocument, run:Void->Void, name:String):Element {
			var button = new ashui.components.Button({size:Icon,variant:Ghost,onClick:_ -> run()}, [new ashui.components.Icon({document:icon})]);
			Identity.of(button.tree, button.node.id).addClasses(["rayde-md-diagram-" + name]);
			return new ashui.components.Tooltip({label:label,side:"bottom"}, [button]);
		}
		toolbar.appendChild(new Text("Drag to pan · Scroll to zoom"));
		toolbar.appendChild(action("Zoom out", rayde.ui.Icons.ZOOM_OUT_LINE, () -> zoom(.8), "out"));
		toolbar.appendChild(action("Zoom in", rayde.ui.Icons.ZOOM_IN_LINE, () -> zoom(1.25), "in"));
		toolbar.appendChild(action("Fit diagram", rayde.ui.Icons.FOCUS_3_LINE, fit, "fit"));
		frame.appendChild(toolbar); frame.appendChild(area);
		var initial = true;
		var settle:ashui.layout.LayoutTree->Void = tree -> {
			if (tree != frame.tree || !initial) return;
			var bounds = tree.getBounds(area.node);
			if (bounds != null && bounds.width > 0 && bounds.height > 0) { initial = false; fit(); }
		};
		ashui.layout.LayoutTree.settledHooks.push(settle);
		Owner.onCleanup(() -> ashui.layout.LayoutTree.settledHooks.remove(settle));
		return frame;
	}

	// Ashui interns SVGs for icons. Document-specific SVGs leave that registry when their last view is released.
	static function acquire(markup:String):SvgDocument {
		var next = @:privateAccess SvgDocument.nextId;
		var doc = SvgDocument.parse(markup), owned = drawings.get(doc.id);
		if (owned != null) owned.uses++;
		else if (doc.id >= next) drawings.set(doc.id, {document:doc, uses:1});
		return doc;
	}

	static function release(doc:SvgDocument):Void {
		var owned = drawings.get(doc.id);
		if (owned == null || --owned.uses > 0) return;
		drawings.remove(doc.id);
		@:privateAccess SvgDocument.byMarkup.remove(doc.markup);
		@:privateAccess SvgDocument.byId.remove(doc.id);
	}

	public function reveal(id:String):Void {
		var heading = headings.get(StringTools.urlDecode(id)), scroll:ashui.input.Scroll = null;
		for (ancestor in node.tree.ancestors(node.id)) {
			scroll = ashui.input.Scroll.at(ancestor, node.tree);
			if (scroll != null) break;
		}
		if (heading == null || scroll == null) return;
		var target = node.tree.getScrolledBounds(heading), view = node.tree.getScrolledBounds(scroll.node);
		scroll.scrollTo(scroll.x.get(), scroll.y.get() + target.y - view.y - 16);
	}
}
