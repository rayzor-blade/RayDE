package rayde.ext;

import ashui.components.Collapsible;
import ashui.components.Icon;
import ashui.components.Resizable;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.layout.Prop;
import ashui.reactive.Computed;
import ashui.reactive.Signal;
import ashui.ui.Text;

private typedef Panel = {
	id:String,
	opened:Signal<Bool>,
	size:Signal<Float>,
	expanded:Float,
	content:Node
};

/** Native split panels with collapsible headers; script children are placed in named slots. */
class BridgePanels {
	final tree:LayoutTree;
	final host:Node;
	final emit:(String, Dynamic)->Void;
	final saved:Dynamic;
	final panels:Array<Panel> = [];
	var config:Array<Dynamic> = [];
	var signature = "";
	var built = false;

	public function new(tree:LayoutTree, host:Node, emit:(String, Dynamic)->Void, saved:Dynamic) {
		this.tree = tree; this.host = host; this.emit = emit; this.saved = saved;
	}

	public function set(data:Dynamic):Void {
		if (!Std.isOfType(data, Array) || (data:Array<Dynamic>).length > 16) throw "Panel configuration must be an array of at most 16 panels";
		var json = haxe.Json.stringify(data);
		if (built && json != signature) throw "Panel configuration is fixed for a mounted group";
		var ids = new Map<String, Bool>();
		var next = [for (p in (data:Array<Dynamic>)) {
			var id = CanvasScene.text(p, "id"), title = CanvasScene.text(p, "title");
			if (id == "" || ids.exists(id)) throw "Panel ids must be nonempty and unique";
			ids.set(id, true);
			{id:id, title:title, open:p.open != false,
				size:p.size == null ? Math.NaN : CanvasScene.number(p, "size", 32, 32),
				minSize:CanvasScene.number(p, "minSize", 32, 32)};
		}];
		config = next; signature = json;
	}

	public function build():Void {
		if (built) return;
		built = true;
		var children:Array<Element> = [];
		for (p in config) {
			var previous:Dynamic = null;
			if (saved != null) for (s in (saved:Array<Dynamic>)) if (s.id == p.id) previous = s;
			var opened = Signal.make(previous == null ? (p.open:Bool) : (previous.open:Bool));
			var initial:Float = previous == null ? p.size : previous.size == null ? Math.NaN : previous.size;
			var size = Signal.make(opened.get() ? initial : 32.);
			var body = new CollapsibleContent({});
			body.node.set(Prop.MinHeight, (0:Single));
			body.node.set(Prop.FlexBasis, (0:Single));
			body.node.set(Prop.FlexGrow, Computed.make(() -> (opened.get() ? 1. : 0. : Single)));
			var arrow = new Icon({document: rayde.ui.Icons.ARROW_RIGHT_S_LINE});
			arrow.node.set(Prop.Width, (14:Single)); arrow.node.set(Prop.Height, (14:Single));
			arrow.node.set(Prop.Transform, Computed.make(() -> new ashui.types.Transform(0, 0, opened.get() ? 90 : 0)));
			var trigger = new CollapsibleTrigger({id:"rayde-panel-toggle-" + p.id}, [arrow, new Text((p.title:String), {fontSize:12, wrap:false})]);
			trigger.node.set(Prop.WidthPercent, (1:Single));
			trigger.node.set(Prop.Height, (28:Single));
			trigger.node.set(Prop.FlexShrink, (0:Single));
			var record:Panel = {id:p.id, opened:opened, size:size, expanded:previous == null ? initial : previous.expanded == null ? Math.NaN : previous.expanded, content:body.node};
			var panel:ResizablePanel = null;
			var collapsible = new Collapsible({open:opened, onOpenChange:open -> {
				if (!open) {
					record.expanded = size.get();
					size.set(32);
				} else size.set(record.expanded);
				emit("panelChange", {id:record.id, open:open});
			}}, [trigger, body]);
			collapsible.node.set(Prop.HeightPercent, (1:Single));
			collapsible.node.set(Prop.MinHeight, (0:Single));
			panel = new ResizablePanel({id:"rayde-panel-" + p.id, size:size, minSize:p.minSize}, [collapsible]);
			panels.push(record); children.push(panel);
		}
		var group = new Resizable({direction:"vertical"}, children);
		group.node.set(Prop.WidthPercent, (1:Single));
		group.node.set(Prop.HeightPercent, (1:Single));
		tree.addChild(host.id, group.node.id);
	}

	public function place(children:Array<{slot:String, node:Node}>):Void {
		for (p in panels) tree.replaceChildren(p.content.id, [for (c in children) if (c.slot == p.id) c.node.id]);
	}

	public function state():Dynamic
		return [for (p in panels) {id:p.id, open:p.opened.get(), size:Math.isNaN(p.size.get()) ? null : p.size.get(),
			expanded:Math.isNaN(p.expanded) ? null : p.expanded}];
}
