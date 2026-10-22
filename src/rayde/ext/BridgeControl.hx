package rayde.ext;

import ashui.canvaskit.Background2D;
import ashui.canvaskit.CanvasKit;
import ashui.canvaskit.Selection2D;
import ashui.canvaskit.Viewport2D;
import ashui.components.Button;
import ashui.components.CodeDiff;
import ashui.components.Icon;
import ashui.components.Select;
import ashui.components.Tooltip;
import ashui.components.DropdownMenu;
import ashui.css.Identity;
import ashui.input.Interaction;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.layout.Prop;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.reactive.Computed;
import ashui.reactive.Watch;
import ashui.ui.Div;
import ashui.types.Style;

/** Scoped native controls behind serializable extension properties and semantic events. */
class BridgeControl {
	public final node:Node;
	public var content(default, null):Null<Node>;
	public final kind:String;
	public var panels(default, null):Null<BridgePanels>;
	final tree:LayoutTree;
	final emit:(String, Dynamic)->Void;
	final disabled = Signal.make(false);
	final value = Signal.make("");
	var stop:Void->Void;
	var scope:Owner;
	var options:Array<Dynamic> = [];
	var dirty = false;
	var stopSelect:Null<Void->Void>;
	var stopIcon:Null<Void->Void>;
	var nativeButton:Button;
	var nativeSelect:Select;
	var kit:CanvasKit;
	var viewport:Viewport2D;
	var selection:Selection2D;
	var scene = Signal.make(new CanvasScene(null));
	var hovered = Signal.make("");
	var pending:Dynamic;
	var lastCommand = "";
	var reported = "[]";
	var selectSize = "sm";
	var panelState:Dynamic;
	var navigation = "canvas";
	var textRendering = "paths";
	var scroller:Null<ashui.input.Scroll>;
	var restoreScroll:Dynamic;
	var tooltip:Null<String>;
	var buttonMounted = false;
	var markdownSource:Dynamic;
	final markdownDocument = Signal.make((null:Dynamic));
	final markdownVisible = Signal.make(true);
	var markdown:MarkdownView;
	final diffOriginal = Signal.make("");
	final diffModified = Signal.make("");
	final diffLanguage = Signal.make("plain");
	final diffLayout = Signal.make((Inline:CodeDiffLayout));
	var diffNavigation = false;
	var diff:Null<CodeDiff>;
	final image:Null<(String, String)->{bytes:haxe.io.Bytes, svg:Bool}>;
	final markdownState:Dynamic;

	public static function supported(tag:String):Bool
		return tag == "markdown-view" || tag == "code-diff" || tag == "canvas-kit" || tag == "ui-button" || tag == "ui-menu" || tag == "ui-select" || tag == "ui-panel-group" || tag == "ui-icon";

	public function new(tree:LayoutTree, kind:String, emit:(String, Dynamic)->Void, ?state:Dynamic, ?image:(String, String)->{bytes:haxe.io.Bytes, svg:Bool}) {
		this.tree = tree;
		this.image = image;
		markdownState = state;
		this.kind = kind;
		this.emit = emit;
		var box:Div = Owner.root(tree, dispose -> {
			stop = dispose;
			scope = Owner.current;
			var box = new Div({display: Flex, minWidth: 0, minHeight: 0});
			if (kind == "ui-button") {
				var slot = new Div({display: Flex, alignItems: Center, justifyContent: ashui.types.Justify.Center});
				content = slot.node;
				content.set(Prop.WidthPercent, (1:Single));
				nativeButton = new Button({size: Sm, variant: Secondary, disabled: disabled, type: "button",
					onClick: e -> emit("click", {x: e.localX, y: e.localY})}, [slot]);
				fill(nativeButton);
			} else if (kind == "canvas-kit") {
				viewport = new Viewport2D();
				selection = new Selection2D();
				if (state != null) {
					viewport.panX.set(state.x); viewport.panY.set(state.y); viewport.zoom.set(state.zoom);
					lastCommand = state.command;
				}
				if (state != null && state.scrollX != null) restoreScroll = {x:state.scrollX, y:state.scrollY};
				new Watch(() -> selection.ids.get(), ids -> {
					var json = haxe.Json.stringify(ids);
					if (json != reported) { reported = json; emit("selectionChange", {ids: ids}); }
				});
			} else if (kind == "ui-panel-group") panelState = state;
			else dirty = true;
			return box;
		});
		node = box.node;
		if (kind == "ui-panel-group") panels = new BridgePanels(tree, node, emit, panelState);
		else if (kind == "markdown-view") {
			node.set(Prop.FlexDirection, Column);
			node.set(Prop.FlexShrink, (0:Single));
		}
		else if (kind == "code-diff") {
			node.set(Prop.FlexDirection, Column);
			node.set(Prop.FlexGrow, (1:Single));
		}
		else if (kind == "ui-icon") {
			node.set(Prop.Width, (16:Single)); node.set(Prop.Height, (16:Single));
			node.set(Prop.FlexShrink, (0:Single));
		}
		else if (kind != "canvas-kit" && kind != "markdown-view" && kind != "code-diff") node.set(Prop.Height, (32:Single));
	}

	function buildCanvas():Void {
		if (kit != null) return;
		var scrolling = navigation == "scroll";
		var nativeText = textRendering == "native";
		if (nativeText && !scrolling) throw "Native canvas labels require scrolling navigation";
		if (scrolling) viewport.reset();
		kit = new CanvasKit({viewport:viewport, selection:selection, interactive:!scrolling, background:new Background2D(None),
			draw:(ctx, canvas) -> scene.get().draw(ctx, canvas, hovered.get(), scrolling, nativeText),
			onClick:(id, e) -> clickRegion(id, e),
			onHover:id -> { hovered.set(id ?? ""); emit("hover", {region:id}); }});
		kit.momentumDecay = 0;
		if (scrolling) {
			node.set(Prop.Overflow, ashui.types.Overflow.Scroll);
			scroller = ashui.input.Scroll.attach(node, true, true);
			// Only the spacer has the full scene's extent; the GPU canvas stays viewport-sized.
			var spacer = new Div({flexShrink:0});
			tree.addChild(node.id, spacer.node.id);
			kit.node.set(Prop.Position, Absolute);
			fill(kit);
			new Watch(() -> scene.get().bounds, b -> {
				spacer.node.set(Prop.Width, (Math.max(1, b.x + b.width):Single));
				spacer.node.set(Prop.Height, (Math.max(1, b.y + b.height):Single));
			});
			new Watch(() -> ({x:scroller.x.get(), y:scroller.y.get()}), offset -> {
				// Counter the native content offset, then draw the visible slice in content coordinates.
				kit.node.set(Prop.Left, (offset.x:Single));
				kit.node.set(Prop.Top, (offset.y:Single));
				viewport.panX.set(-offset.x); viewport.panY.set(-offset.y);
				hovered.set("");
			});
			var input = Interaction.of(kit.node);
			input.onPointerMove(e -> {
				var point = viewport.screenToContent(e.localX, e.localY);
				var hit = kit.index.hitTest(point.x, point.y), id = hit == null ? "" : hit.id;
				if (hovered.get() != id) { hovered.set(id); emit("hover", {region:hit == null ? null : id}); }
			});
			input.onPointerLeave(_ -> { hovered.set(""); emit("hover", {region:null}); });
			input.onClick(e -> {
				if (e.button != null && e.button != Left) return;
				var point = viewport.screenToContent(e.localX, e.localY);
				var hit = kit.index.hitTest(point.x, point.y);
				if (hit == null) return;
				if (e.control || e.superKey) selection.toggle(hit.id); else if (e.shift) selection.add(hit.id); else selection.select(hit.id);
				clickRegion(hit.id, e);
			});
		} else fill(kit);
		tree.addChild(node.id, kit.node.id);
		var labels = nativeText ? new CanvasLabels(node, Owner.current) : null;
		if (labels != null) {
			var placeLabels:LayoutTree->Bool = laid -> {
				if (laid != tree) return false;
				var bounds = tree.getBounds(node);
				return bounds != null && bounds.width > 0 && bounds.height > 0
					&& labels.update(scene.get(), scroller.x.get(), scroller.y.get(), bounds.width, bounds.height);
			};
			LayoutTree.layoutHooks.push(placeLabels);
			Owner.onCleanup(() -> {
				for (i in 0...LayoutTree.layoutHooks.length) if (Reflect.compareMethods(LayoutTree.layoutHooks[i], placeLabels)) { LayoutTree.layoutHooks.splice(i, 1); break; }
			});
		}
		var settle:LayoutTree->Void = laid -> {
			if (laid != tree) return;
			var bounds = tree.getBounds(node);
			if (bounds == null || bounds.width <= 0 || bounds.height <= 0) return;
			if (scrolling) {
				var extent = scene.get().bounds;
				var maxX = Math.max(0, extent.x + extent.width - bounds.width), maxY = Math.max(0, extent.y + extent.height - bounds.height);
				if (scroller.x.get() > maxX || scroller.y.get() > maxY) scroller.scrollTo(Math.min(scroller.x.get(), maxX), Math.min(scroller.y.get(), maxY));
				if (restoreScroll != null) { scroller.scrollTo(restoreScroll.x, restoreScroll.y); restoreScroll = null; }
				if (pending != null) { scroller.scrollTo(0, 0); pending = null; }
				return;
			}
			if (pending == null) return;
			var command = pending; pending = null;
			var s = scene.get().bounds;
			switch (command.action : String) {
				case "fit": viewport.fit(s.x, s.y, s.width, s.height, bounds.width, bounds.height, 0);
				case "reset": viewport.reset();
				case "zoom": viewport.zoomAt(bounds.width/2, bounds.height/2, command.factor);
			}
		};
		LayoutTree.settledHooks.push(settle);
		Owner.onCleanup(() -> LayoutTree.settledHooks.remove(settle));
	}

	function clickRegion(id:String, e:ashui.input.Events.PointerEvent):Void {
		var point = navigation == "scroll" ? viewport.screenToContent(e.localX, e.localY) : {x:e.localX, y:e.localY};
		emit("click", {region:id, x:point.x, y:point.y, shift:e.shift, control:e.control, meta:e.superKey});
	}

	static function fill(element:Element):Void {
		element.node.set(Prop.WidthPercent, (1:Single));
		element.node.set(Prop.HeightPercent, (1:Single));
	}

	public function handles(event:String):Bool
		return kind == "markdown-view" && event == "link" || kind == "ui-button" && event == "click" || kind == "ui-select" && event == "change"
			|| kind == "ui-menu" && event == "select"
			|| kind == "ui-panel-group" && event == "panelChange"
			|| kind == "canvas-kit" && ["click", "hover", "selectionChange"].indexOf(event) >= 0;

	public function set(name:String, data:Dynamic):Bool {
		switch name {
			case "document" if (kind == "markdown-view"):
				markdownSource = data;
				markdownDocument.set(data == null ? null : Std.isOfType(data, String) ? haxe.Json.parse(data) : data); return true;
			case "original" if (kind == "code-diff"): diffOriginal.set(data == null ? "" : Std.string(data)); return true;
			case "modified" if (kind == "code-diff"): diffModified.set(data == null ? "" : Std.string(data)); return true;
			case "language" if (kind == "code-diff"): diffLanguage.set(data == null ? "plain" : Std.string(data)); return true;
			case "layout" if (kind == "code-diff"):
				var mode = data == null ? "inline" : Std.string(data);
				if (["inline", "split"].indexOf(mode) < 0) throw "Unknown diff layout";
				diffLayout.set(mode); return true;
			case "navigation" if (kind == "code-diff"):
				if (diff != null && (data == true) != diffNavigation) throw "Diff navigation is fixed while mounted";
				diffNavigation = data == true; return true;
			case "navigation" if (kind == "canvas-kit"):
				var mode = data == null ? "canvas" : Std.string(data);
				if (["canvas", "scroll"].indexOf(mode) < 0) throw "Unknown canvas navigation";
				if (kit != null && mode != navigation) throw "Canvas navigation is fixed while mounted";
				navigation = mode; return true;
			case "textRendering" if (kind == "canvas-kit"):
				var mode = data == null ? "paths" : Std.string(data);
				if (["paths", "native"].indexOf(mode) < 0) throw "Unknown canvas text rendering";
				if (kit != null && mode != textRendering) throw "Canvas text rendering is fixed while mounted";
				textRendering = mode; return true;
			case "name" if (kind == "ui-icon"):
				var name = data == null ? null : CanvasScene.text({name:data}, "name");
				var document = rayde.ui.ViewIcons.named(null, name);
				if (name != null && document == null) throw 'Unknown icon $name';
				if (stopIcon != null) stopIcon();
				if (document != null) scope.run(() -> {
					var child = new Owner(tree);
					stopIcon = child.dispose;
					child.run(() -> {
						var icon = new Icon({document:document});
						fill(icon); tree.addChild(node.id, icon.node.id);
					});
				});
				return true;
			case "aria-label" if (kind == "ui-button"):
				Identity.of(tree, nativeButton.node.id).setAttribute(name, data == null ? null : Std.string(data)); return true;
			case "tooltip" if (kind == "ui-button" || kind == "ui-menu"):
				var label = data == null ? null : Std.string(data);
				if (buttonMounted && label != tooltip) throw "Button tooltip is fixed while mounted";
				tooltip = label;
				if (label != null && nativeButton != null) Identity.of(tree, nativeButton.node.id).setAttribute("aria-label", label);
				return true;
			case "panels" if (panels != null): panels.set(data); return true;
			case "height" if (kind == "ui-button" || kind == "ui-select"):
				var height = data == null ? 32. : CanvasScene.finite(data);
				if (height < 16 || height > 256) throw "Control height is out of range";
				node.set(Prop.Height, (height:Single)); return true;
			case "disabled" if (kind != "canvas-kit"): disabled.set(data == true); return true;
			case "value" if (kind == "ui-select"): value.set(data == null ? "" : Std.string(data)); return true;
			case "options" if (kind == "ui-select" || kind == "ui-menu"):
				if (data != null && !Std.isOfType(data, Array)) throw "Control options must be an array";
				options = data == null ? [] : [for (o in (data:Array<Dynamic>)) {
					{value: CanvasScene.text(o, "value"), label: CanvasScene.text(o, "label"), disabled: o.disabled == true};
				}];
				dirty = true; return true;
			case "size" if (kind == "ui-button" || kind == "ui-select"):
				var size = data == null ? "sm" : Std.string(data);
				if (["sm", "md", "lg"].indexOf(size) < 0 && !(kind == "ui-button" && size == "icon")) throw "Unknown component size";
				if (kind == "ui-button") Identity.of(tree, nativeButton.node.id).setAttribute("data-size", size);
				else { selectSize = size; dirty = true; }
				return true;
			case "variant" if (kind == "ui-button"):
				var variant = data == null ? "secondary" : Std.string(data);
				if (["primary", "secondary", "outline", "ghost", "link", "destructive"].indexOf(variant) < 0) throw "Unknown button variant";
				Identity.of(tree, nativeButton.node.id).setAttribute("data-variant", variant); return true;
			case "scene" if (kind == "canvas-kit"): scene.set(new CanvasScene(data)); return true;
			case "selected" if (kind == "canvas-kit"):
				if (data != null && !Std.isOfType(data, Array)) throw "Canvas selection must be an array";
				var ids:Array<String> = data == null ? [] : [for (id in (data:Array<Dynamic>)) {
					if (!Std.isOfType(id, String)) throw "Canvas selection ids must be strings";
					(id:String);
				}];
				reported = haxe.Json.stringify(ids); selection.set(ids); return true;
			case "command" if (kind == "canvas-kit"):
				if (data != null && haxe.Json.stringify(data) != lastCommand) {
					var action = CanvasScene.text(data, "action");
					if (["fit", "reset", "zoom"].indexOf(action) < 0) throw "Unknown canvas command";
					if (navigation == "scroll" && action != "reset") throw "Scrolling canvases support reset only";
					var factor = CanvasScene.number(data, "factor", 1, .01, 100);
					lastCommand = haxe.Json.stringify(data); pending = {action: action, factor: factor};
					if (kit != null) kit.repaint();
				}
				return true;
			case _:
		}
		return false;
	}

	public function flush():Void {
		if (kind == "markdown-view") {
			if (markdown == null) scope.run(() -> {
				markdown = new MarkdownView(markdownDocument, emit, markdownVisible, image, markdownState, () -> markdownSource);
				tree.addChild(node.id, markdown.node.id);
			});
			return;
		}
		if (kind == "code-diff") {
			if (diff == null) scope.run(() -> {
				diff = new CodeDiff({original:diffOriginal, modified:diffModified, language:diffLanguage, layout:diffLayout, navigation:diffNavigation});
				fill(diff);
				tree.addChild(node.id, diff.node.id);
			});
			return;
		}
		if (kind == "ui-button" && !buttonMounted) {
			scope.run(() -> {
				if (tooltip != null) {
					var tip = new Tooltip({label:tooltip, side:"bottom"}, [nativeButton]);
					fill(tip); tree.addChild(node.id, tip.node.id);
				} else tree.addChild(node.id, nativeButton.node.id);
			});
			buttonMounted = true;
		}
		if (kind == "canvas-kit") { scope.run(buildCanvas); return; }
		if (panels != null) { scope.run(() -> panels.build()); return; }
		if ((kind != "ui-select" && kind != "ui-menu") || !dirty) return;
		dirty = false;
		if (stopSelect != null) stopSelect();
		scope.run(() -> {
			var child = new Owner(tree);
			stopSelect = child.dispose;
			child.run(() -> {
				if (kind == "ui-menu") {
					var trigger = new DropdownMenuTrigger({variant:Ghost, size:Icon}, []);
					fill(trigger);
					Interaction.of(trigger.node).setDisabled(disabled);
					if (tooltip != null) Identity.of(tree, trigger.node.id).setAttribute("aria-label", tooltip);
					var items:Array<Element> = [for (o in options) new DropdownMenuItem({
						disabled:Computed.make(() -> disabled.get() || o.disabled), onSelect:() -> emit("select", {value:o.value})
					}, [new ashui.ui.Text(Std.string(o.label))])];
					var menu = new DropdownMenu({}, [trigger, new DropdownMenuContent({}, items)]);
					fill(menu);
					var element:Element = tooltip == null ? menu : new Tooltip({label:tooltip, side:"bottom"}, [menu]);
					fill(element); tree.addChild(node.id, element.node.id);
					buttonMounted = true;
					return;
				}
				var items:Array<Element> = [for (o in options) new SelectItem({value: o.value, label: o.label, disabled: o.disabled})];
				nativeSelect = new Select({value: value, disabled: disabled, size: cast selectSize, onChange: v -> emit("change", {value: v})}, items);
				fill(nativeSelect);
				tree.addChild(node.id, nativeSelect.node.id);
			});
		});
	}

	public function state():Dynamic
		return panels != null ? panels.state() : markdown != null ? markdown.state() : kind == "canvas-kit" ? {x: viewport.panX.get(), y: viewport.panY.get(), zoom: viewport.zoom.get(), command: lastCommand, scrollX:scroller == null ? 0. : scroller.x.get(), scrollY:scroller == null ? 0. : scroller.y.get()} : null;

	public function dispose():Void
		stop();

	public function setVisible(value:Bool):Void
		markdownVisible.set(value);
}
