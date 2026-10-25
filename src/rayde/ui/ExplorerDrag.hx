package rayde.ui;

import ashui.animation.AnimationScheduler;
import ashui.input.Events.PointerEvent;
import ashui.input.Pointer;
import ashui.input.Scroll;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.reactive.Signal;

typedef ExplorerDrop = {path:String, directory:Bool};

/** A tree gesture keeps paths, so virtual rows can be released while scrolling. */
class ExplorerDrag {
	public final file = Signal.make("");
	public final target = Signal.make("");
	public final x = Signal.make(0.);
	public final y = Signal.make(0.);
	final box:Element;
	final root:String;
	final scroll:Scroll;
	final hit:(Float, Float)->Null<ExplorerDrop>;
	final expand:String->Void;
	final move:(String, String)->Void;
	var source = "";
	var startX = 0.;
	var startY = 0.;
	var started = false;
	var suppressed = false;
	var hook:Null<LayoutTree->Void>;
	var hover:Null<ashui.animation.AnimationScheduler.Timer>;
	var edge:Null<ashui.animation.AnimationScheduler.Timer>;
	var hovered = "";

	public function new(box:Element, root:String, scroll:Scroll, hit:(Float,Float)->Null<ExplorerDrop>, expand:String->Void, move:(String,String)->Void) {
		this.box = box; this.root = root; this.scroll = scroll; this.hit = hit; this.expand = expand; this.move = move;
	}

	public function begin(path:String, event:PointerEvent):Void {
		if (event.button == null || !event.button.match(Left)) return;
		cancel(); suppressed = false;
		if (path == root) return;
		source = path; startX = event.x; startY = event.y;
		hook = tree -> if (tree == box.tree) update();
		Pointer.hooks.push(hook);
	}

	public function suppressClick():Bool return suppressed;
	public function active():Bool return source != "";
	public function abort():Void { suppressed = true; cancel(); }
	public function cancel():Void {
		source = ""; started = false; hovered = "";
		if (hook != null) Pointer.hooks.remove(hook); hook = null;
		if (hover != null) hover.cancel(); hover = null;
		if (edge != null) edge.cancel(); edge = null;
		file.set(""); target.set("");
	}

	function update():Void {
		if (source == "") return;
		var point = Pointer.at(box.tree);
		if (!point.inside) { cancel(); return; }
		if (!started && point.pressed) {
			var dx = point.x-startX, dy = point.y-startY;
			if (dx*dx+dy*dy < 36) return;
			started = true; suppressed = true; file.set(source);
		}
		var found = started ? hit(point.x, point.y) : null;
		var dir = found == null ? "" : found.directory ? found.path : haxe.io.Path.directory(found.path);
		if (dir == source || StringTools.startsWith(dir, source + "/") || haxe.io.Path.directory(source) == dir) dir = "";
		if (!point.pressed) {
			var from = source; cancel();
			if (dir != "") move(from, dir);
			return;
		}
		if (!started) return;
		target.set(dir);
		var bounds = box.tree.getScrolledBounds(box.node);
		x.set(point.x-bounds.x+12); y.set(point.y-bounds.y+12);
		var next = dir != "" && found != null && found.directory ? found.path : "";
		if (next != hovered) {
			if (hover != null) hover.cancel(); hover = null; hovered = next;
			if (next != "") hover = AnimationScheduler.main.after(.65, () -> { hover = null; if (source != "" && hovered == next) { expand(next); update(); } });
		}
		var direction = found == null ? 0 : point.y < bounds.y+22 ? -1 : point.y > bounds.y+bounds.height-22 ? 1 : 0;
		if (direction != 0 && edge == null) edge = AnimationScheduler.main.after(1/60, () -> {
			edge = null;
			if (source == "") return;
			scroll.jumpTo(scroll.x.get(), scroll.y.get()+direction*12); update();
		});
		if (direction == 0 && edge != null) { edge.cancel(); edge = null; }
	}
}
