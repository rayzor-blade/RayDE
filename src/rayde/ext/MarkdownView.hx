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
import rayde.ui.SvgDocuments;

/** A document owns its text, code viewers and vector images; replacing or hiding it releases them together. */
class MarkdownView {
	public final node:Node;
	public var diagrams(default, null):Array<ashui.canvaskit.CanvasKit> = [];
	final document:Signal<Dynamic>;
	final emit:(String, Dynamic)->Void;
	var child:Owner;
	var bitmaps:Array<ashui.types.Bitmap> = [];
	var baseFile = "";
	var savedScroll:Dynamic;
	var detailStates:Map<Int, Bool> = [];
	var detailIndex = 0;
	var detailKeys = new haxe.ds.ObjectMap<{}, Int>();
	var headingBlocks:Map<String, Int> = [];
	var blocks:MarkdownBlocks;
	final compact:Bool;
	final documentKey:Void->Dynamic;
	final loadImage:Null<(String, String)->{bytes:haxe.io.Bytes, svg:Bool}>;
	var headings:Map<String, Node> = [];

	public function new(document:Signal<Dynamic>, emit:(String, Dynamic)->Void, ?visible:Signal<Bool>, ?loadImage:(String, String)->{bytes:haxe.io.Bytes, svg:Bool}, ?scrollState:Dynamic, ?documentKey:Void->Dynamic, compact = false) {
		this.compact = compact;
		this.documentKey = documentKey == null ? () -> document.get() : documentKey;
		this.document = document;
		this.emit = emit;
		this.loadImage = loadImage;
		savedScroll = scrollState;
		if (scrollState != null && scrollState.details != null) detailStates = scrollState.details;
		if (visible == null) visible = Signal.make(true);
		var body = box(compact ? "rayde-markdown rayde-hover-markdown" : "rayde-markdown");
		node = body.node;
		new Watch(() -> { ThemeState.get().revision.get(); return {data:visible.get() ? document.get() : null, scheme:ThemeState.get().scheme()}; }, value -> {
			var timing = Timing.start();
			var data = value.data;
			baseFile = data == null || data.baseFile == null ? "" : Std.string(data.baseFile);
			if (child != null) {
				if (blocks != null) savedScroll = state();
				child.dispose();
			}
			diagrams = [];
			bitmaps = [];
			detailIndex = 0;
			headings = [];
			child = new Owner(body.tree);
			blocks = null;
			detailKeys = new haxe.ds.ObjectMap(); headingBlocks = [];
			child.run(() -> {
				if (data != null) {
					var items = children(data);
					function index(part:Dynamic, block:Int):Void {
						if (part.kind == "details") detailKeys.set(part, detailIndex++);
						if (part.id != null) headingBlocks.set((part.kind == "footnote" ? "footnote-" : "") + Std.string(part.id), block);
						for (item in children(part)) index(item, block);
					}
					for (i in 0...items.length) index(items[i], i);
					if (compact) appendBlocks(body, items);
					else {
						blocks = new MarkdownBlocks(items, (part, _) -> render(part), estimate, measurementKey, this.documentKey(), savedScroll);
						body.tree.addChild(body.node.id, blocks.node.id);
					}
				}
			});
			if (Timing.enabled) Timing.end(timing, "markdown.build", {visible:data != null});
		}, (a, b) -> a.data == b.data && a.scheme == b.scheme);
		Owner.onCleanup(() -> { if (child != null) child.dispose(); headings.clear(); diagrams = []; bitmaps = []; });
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
			if (compact) {
				var syntax = rayde.ui.TextMateSyntax.fromTokens(data.tokens), state = "";
				for (line in Std.string(data.text).split("\n")) {
					var row = box("ui-code-hint-line"), result = syntax.highlight(line, state);
					state = result.state;
					var tokens:Array<ashui.components.code.CodeHighlighter.CodeToken> = result.tokens.length == 0 ? [{from:0, to:line.length, kind:Plain}] : result.tokens;
					for (token in tokens) {
						var run = new Text(line == "" ? " " : line.substring(token.from, token.to));
						var identity = Identity.of(run.tree, run.node.id);
						identity.setClasses(["ui-code-text", "ui-code-hint-token"]);
						identity.setAttribute("data-token", token.kind);
						row.appendChild(run);
					}
					frame.appendChild(row);
				}
				return frame;
			}
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
		if (kind == "image") return image(data);
		if (kind == "details") {
			var key = detailKeys.get(data);
			var view = new ashui.ui.Details({open:detailStates.exists(key) ? detailStates.get(key) : data.open == true, onToggle:open -> detailStates.set(key, open)}, [for (part in children(data)) render(part)]);
			decorate(view, data); return view;
		}
		if (kind == "summary") {
			var content = box("rayde-md-paragraph");
			for (part in children(data)) inlinePart(content, part, [], null);
			ashui.text.InlineFlow.attach(content);
			var view = new ashui.ui.Summary({}, [content]); decorate(view, data); return view;
		}
		if (["text", "em", "strong", "strike", "link", "inline-code", "task", "inline", "break"].indexOf(kind) >= 0) {
			var line = box("rayde-md-paragraph");
			inlinePart(line, data, [], null);
			ashui.text.InlineFlow.attach(line);
			return line;
		}
		var classes = switch kind {
			case "heading": "rayde-md-heading rayde-md-h" + data.level;
			case "group": "rayde-md-group";
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
		decorate(container, data);
		if (kind == "heading" || kind == "footnote") {
			var id = (kind == "footnote" ? "footnote-" : "") + Std.string(data.id);
			registerHeading(id, container.node);
			Identity.of(container.tree, container.node.id).setAttribute("data-md-heading", id);
		}
		if (["heading", "paragraph", "html", "table-cell"].indexOf(kind) >= 0) {
			for (part in children(data)) inlinePart(container, part, [], null);
			ashui.text.InlineFlow.attach(container);
		} else if (kind == "list") {
			var index:Int = data.start == null ? 0 : Std.int(data.start);
			for (item in children(data)) {
				var row = box("rayde-md-list-row"), content = box("rayde-md-list-content");
				if (!Lambda.exists(children(item), part -> part.kind == "task" || part.kind == "paragraph" && Lambda.exists(children(part), p -> p.kind == "task"))) row.appendChild(new Text(data.start == null ? "•" : (index++) + "."));
				var line:Div = null;
				for (part in children(item)) {
					if (["text", "em", "strong", "strike", "link", "inline-code", "task", "inline", "break"].indexOf(part.kind) >= 0) {
						if (line == null) { line = box("rayde-md-paragraph"); content.appendChild(line); ashui.text.InlineFlow.attach(line); }
						inlinePart(line, part, [], null);
					} else { line = null; content.appendChild(render(part)); }
				}
				row.appendChild(content); container.appendChild(row);
			}
		} else if (kind == "group") {
			appendBlocks(container, children(data));
		} else {
			if (kind == "table") for (row in children(data)) {
				var cells = children(row), align:Array<String> = data.align;
				for (i in 0...cells.length) if (align != null && i < align.length) cells[i].align = align[i];
			}
			for (part in children(data)) {
				if (["text", "em", "strong", "strike", "link", "inline-code", "task", "inline", "break"].indexOf(part.kind) >= 0)
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
		if (kind == "math" || kind == "diagram" || kind == "error" || kind == "image") {
			var view = render(data); if (href != null) link(view.node, href); parent.appendChild(view); return;
		}
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
			case "inline":
				switch Std.string(data.variant) {
					case "sup", "sub", "small", "mark": next.push("rayde-md-" + data.variant);
					case "u", "ins": next.push("rayde-md-underline");
					case _:
				}
			case _:
		}
		if (data.text == null) {
			var target = parent;
			if (data.id != null) { target = span("rayde-md-inline"); decorate(target, data); parent.appendChild(target); }
			for (part in children(data)) inlinePart(target, part, next, href);
			return;
		}
		var source = Std.string(data.text);
		if (source != "") {
			var word = box(["rayde-md-word"].concat(next).join(" "));
			Identity.of(word.tree, word.node.id).types.remove("div");
			Identity.register(word.tree, word.node, "span");
			// InlineFlow measures this run itself and paints separate wrapped pieces.
			var probe = new Text(source, {wrap:false});
			probe.node.set(Prop.Position, ashui.types.Style.Position.Absolute);
			probe.node.set(Prop.Width, (0:Single));
			probe.node.set(Prop.Height, (0:Single));
			word.appendChild(probe);
			decorate(word, data);
			if (href != null) link(word.node, href);
			parent.appendChild(word);
		}
	}

	static function span(classes:String):Div {
		var view = box(classes);
		Identity.of(view.tree, view.node.id).types.remove("div");
		Identity.register(view.tree, view.node, "span");
		return view;
	}

	function link(node:Node, href:String):Void {
		if (href == "") return;
		Interaction.of(node).onClick(_ -> {
			if (StringTools.startsWith(href, "#")) reveal(href.substr(1)); else emit("link", {href:href});
		});
		Identity.of(node.tree, node.id).setAttribute("data-md-link", href);
	}

	function decorate(view:Element, data:Dynamic):Void {
		var identity = Identity.of(view.tree, view.node.id);
		if (data.htmlTag != null) identity.setAttribute("data-md-html", Std.string(data.htmlTag));
		if (data.id != null) registerHeading((data.kind == "footnote" ? "footnote-" : "") + Std.string(data.id), view.node);
		if (data.textAlign != null) identity.setInline("text-align", Std.string(data.textAlign));
	}

	function appendBlocks(parent:Div, parts:Array<Dynamic>):Void {
		var line:Div = null;
		for (part in parts) {
			if (["text", "em", "strong", "strike", "link", "inline-code", "task", "inline", "break", "image"].indexOf(part.kind) >= 0 || part.kind == "math" && part.display != true) {
				if (line == null) { line = box("rayde-md-paragraph"); parent.appendChild(line); ashui.text.InlineFlow.attach(line); }
				inlinePart(line, part, [], null);
			} else { line = null; parent.appendChild(render(part)); }
		}
	}

	function image(data:Dynamic):Element {
		try {
			var picture:Element, width:Float, height:Float;
			var bitmap:ashui.types.Bitmap = null;
			var bytes:haxe.io.Bytes = null, svg = false;
			if (data.svgBytes != null || data.imageBytes != null) {
				svg = data.svgBytes != null;
				bytes = haxe.crypto.Base64.decode(svg ? data.svgBytes : data.imageBytes);
			} else if (loadImage != null) {
				var asset = loadImage(baseFile, Std.string(data.href)); bytes = asset.bytes; svg = asset.svg;
			} else throw "Image unavailable";
			if (svg) {
				var doc = SvgDocuments.acquire(bytes.toString());
				Owner.onCleanup(() -> SvgDocuments.release(doc));
				width = doc.width; height = doc.height;
				picture = new ashui.ui.Svg(doc);
			} else {
				bitmap = ashui.types.Bitmap.fromBytes(bytes);
				bitmaps.push(bitmap);
				Owner.onCleanup(() -> { bitmap.dispose(); bitmaps.remove(bitmap); });
				width = bitmap.width; height = bitmap.height;
				picture = new ashui.ui.Image(bitmap);
			}
			var w:Float = data.width != null ? data.width : data.height != null ? data.height * width / height : Math.min(700, width);
			var h:Float = data.height != null ? data.height : w * height / width;
			if (bitmap != null) bitmap.shrink(Std.int(Math.min(2048, Math.max(1, Math.ceil(Math.max(w, h) * 2)))));
			var frame = box("rayde-md-image");
			Identity.of(frame.tree, frame.node.id).types.remove("div");
			Identity.register(frame.tree, frame.node, "img");
			decorate(frame, data);
			frame.node.set(Prop.Width, (w:Single));
			if (data.widthPercent != null) frame.node.set(Prop.WidthPercent, (data.widthPercent / 100:Single));
			frame.node.set(Prop.MaxWidthPercent, (1:Single));
			frame.node.set(Prop.AspectRatio, (w / h:Single));
			picture.node.set(Prop.Position, ashui.types.Style.Position.Absolute);
			picture.node.set(Prop.Left, (0:Single)); picture.node.set(Prop.Top, (0:Single));
			picture.node.set(Prop.WidthPercent, (1:Single)); picture.node.set(Prop.HeightPercent, (1:Single));
			frame.appendChild(picture);
			return frame;
		} catch (failure:Dynamic) {
			var fallback = span("rayde-md-image-alt");
			fallback.appendChild(new Text("Image: " + text(data) + " — " + Std.string(failure)));
			return fallback;
		}
	}

	function drawing(data:Dynamic):Element {
		var markup:String = data.kind == "diagram" && ThemeState.get().scheme() == Dark && data.darkSvg != null ? data.darkSvg : data.svg;
		var doc = SvgDocuments.acquire(markup);
		Owner.onCleanup(() -> SvgDocuments.release(doc));
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
		Owner.onCleanup(() -> diagrams.remove(kit));
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

	function scroller():Null<ashui.input.Scroll> {
		var scroll:ashui.input.Scroll = null;
		for (ancestor in node.tree.ancestors(node.id)) {
			scroll = ashui.input.Scroll.at(ancestor, node.tree);
			if (scroll != null) break;
		}
		return scroll;
	}

	public function state():Dynamic {
		var scroll = scroller();
		if (blocks == null) return savedScroll;
		var position = scroll == null ? blocks.navigation() : {x:scroll.x.get(), y:scroll.y.get()};
		return {x:position.x, y:position.y, details:detailStates, layout:blocks.state()};
	}

	function registerHeading(id:String, node:Node):Void {
		headings.set(id, node);
		Owner.onCleanup(() -> { if (headings.get(id) == node) headings.remove(id); });
	}

	static function estimate(data:Dynamic, width:Float):Float {
		var chars = Math.max(12, width / 8);
		return switch Std.string(data.kind) {
			case "heading": 26 + Math.ceil(text(data).length / chars) * (data.level == 1 ? 40 : data.level == 2 ? 34 : 30);
			case "code": Math.min(360, Math.max(44, Std.string(data.text).split("\n").length * 21 + 20)) + 50;
			case "diagram": 336;
			case "image": data.height == null ? 300 : (data.height:Float);
			case "math": 100;
			case "rule": 1;
			case "list": Lambda.fold(children(data), (part, sum) -> sum + estimate(part, width-24) + 6, 0.);
			case "table": children(data).length * 44.;
			case "group", "quote", "item": Lambda.fold(children(data), (part, sum) -> sum + estimate(part, width-16) + 16, 0.);
			case _: Math.max(26, Math.ceil(text(data).length / chars) * 26);
		};
	}

	static function measurementKey(data:Dynamic):String
		return haxe.Json.stringify({kind:data.kind, text:text(data), href:data.href, width:data.width, height:data.height,
			level:data.level, language:data.language, align:data.textAlign, start:data.start});

	public function reveal(id:String):Void {
		id = StringTools.urlDecode(id);
		if (blocks == null || !headingBlocks.exists(id)) return;
		blocks.reveal(headingBlocks.get(id), () -> {
			var heading = headings.get(id), scroll = scroller();
			if (heading == null || scroll == null) return false;
			var target = node.tree.getScrolledBounds(heading), view = node.tree.getScrolledBounds(scroll.node);
			if (target == null || view == null) return false;
			scroll.jumpTo(scroll.x.get(), scroll.y.get() + target.y - view.y - 16);
			return true;
		});
	}
}
