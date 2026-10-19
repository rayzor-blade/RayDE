package rayde.ext;

import ashui.canvaskit.Background2D;
import ashui.canvaskit.CanvasKit;
import ashui.canvaskit.Selection2D;
import ashui.canvaskit.Viewport2D;
import ashui.components.Button;
import ashui.components.Select;
import ashui.css.Identity;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.layout.Prop;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
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

	public static function supported(tag:String):Bool
		return tag == "canvas-kit" || tag == "ui-button" || tag == "ui-select" || tag == "ui-panel-group";

	public function new(tree:LayoutTree, kind:String, emit:(String, Dynamic)->Void, ?state:Dynamic) {
		this.tree = tree;
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
				box.appendChild(nativeButton);
			} else if (kind == "canvas-kit") {
				viewport = new Viewport2D();
				selection = new Selection2D();
				if (state != null) {
					viewport.panX.set(state.x); viewport.panY.set(state.y); viewport.zoom.set(state.zoom);
					lastCommand = state.command;
				}
				kit = new CanvasKit({viewport: viewport, selection: selection, background: new Background2D(None),
					draw: (ctx, canvas) -> scene.get().draw(ctx, canvas, hovered.get()),
					onClick: (id, e) -> emit("click", {region: id, x: e.localX, y: e.localY, shift: e.shift, control: e.control, meta: e.superKey}),
					onHover: id -> { hovered.set(id ?? ""); emit("hover", {region: id}); }});
				// A fit command must stop at its target even after a pan gesture.
				kit.momentumDecay = 0;
				fill(kit);
				box.appendChild(kit);
				new Watch(() -> selection.ids.get(), ids -> {
					var json = haxe.Json.stringify(ids);
					if (json != reported) { reported = json; emit("selectionChange", {ids: ids}); }
				});
				var settle:LayoutTree->Void = laid -> {
					if (laid != tree || pending == null) return;
					var bounds = tree.getBounds(kit.node);
					if (bounds == null || bounds.width <= 0 || bounds.height <= 0) return;
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
			} else if (kind == "ui-panel-group") panelState = state;
			else dirty = true;
			return box;
		});
		node = box.node;
		if (kind == "ui-panel-group") panels = new BridgePanels(tree, node, emit, panelState);
		else if (kind != "canvas-kit") node.set(Prop.Height, (32:Single));
	}

	static function fill(element:Element):Void {
		element.node.set(Prop.WidthPercent, (1:Single));
		element.node.set(Prop.HeightPercent, (1:Single));
	}

	public function handles(event:String):Bool
		return kind == "ui-button" && event == "click" || kind == "ui-select" && event == "change"
			|| kind == "ui-panel-group" && event == "panelChange"
			|| kind == "canvas-kit" && ["click", "hover", "selectionChange"].indexOf(event) >= 0;

	public function set(name:String, data:Dynamic):Bool {
		switch name {
			case "panels" if (panels != null): panels.set(data); return true;
			case "height" if (kind == "ui-button" || kind == "ui-select"):
				var height = data == null ? 32. : CanvasScene.finite(data);
				if (height < 16 || height > 256) throw "Control height is out of range";
				node.set(Prop.Height, (height:Single)); return true;
			case "disabled" if (kind != "canvas-kit"): disabled.set(data == true); return true;
			case "value" if (kind == "ui-select"): value.set(data == null ? "" : Std.string(data)); return true;
			case "options" if (kind == "ui-select"):
				if (data != null && !Std.isOfType(data, Array)) throw "ui-select options must be an array";
				options = data == null ? [] : [for (o in (data:Array<Dynamic>)) {
					{value: CanvasScene.text(o, "value"), label: CanvasScene.text(o, "label"), disabled: o.disabled == true};
				}];
				dirty = true; return true;
			case "size" if (kind != "canvas-kit"):
				var size = data == null ? "sm" : Std.string(data);
				if (["sm", "md", "lg"].indexOf(size) < 0) throw "Unknown component size";
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
					var factor = CanvasScene.number(data, "factor", 1, .01, 100);
					lastCommand = haxe.Json.stringify(data); pending = {action: action, factor: factor};
					kit.repaint();
				}
				return true;
			case _:
		}
		return false;
	}

	public function flush():Void {
		if (panels != null) { scope.run(() -> panels.build()); return; }
		if (kind != "ui-select" || !dirty) return;
		dirty = false;
		if (stopSelect != null) stopSelect();
		scope.run(() -> {
			var child = new Owner(tree);
			stopSelect = child.dispose;
			child.run(() -> {
				var items:Array<Element> = [for (o in options) new SelectItem({value: o.value, label: o.label, disabled: o.disabled})];
				nativeSelect = new Select({value: value, disabled: disabled, size: cast selectSize, onChange: v -> emit("change", {value: v})}, items);
				fill(nativeSelect);
				tree.addChild(node.id, nativeSelect.node.id);
			});
		});
	}

	public function state():Dynamic
		return panels != null ? panels.state() : kind == "canvas-kit" ? {x: viewport.panX.get(), y: viewport.panY.get(), zoom: viewport.zoom.get(), command: lastCommand} : null;

	public function dispose():Void
		stop();
}
