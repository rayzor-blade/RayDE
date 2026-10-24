package rayde.ui;

import ashui.animation.AnimationScheduler;
import ashui.css.Css;
import ashui.css.Identity;
import ashui.input.Events.KeyEvent;
import ashui.input.Events.PointerEvent;
import ashui.input.Pointer;
import ashui.input.Scroll;
import ashui.layout.Bounds;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Signal;
import rayde.ui.EditorGroups.EditorGroup;

private typedef Gesture = {source:EditorGroup, pane:Element, file:String, x:Float, y:Float, started:Bool};
private typedef Drop = {group:EditorGroup, index:Null<Int>, marker:Float, top:Float, height:Float, scroll:Null<Scroll>, edge:Int};

/** A window's tab gesture. Input hooks and scrolling exist only while the pointer is held. */
class EditorTabDrag {
	public final file = Signal.make("");
	public final target = Signal.make(-1);
	public final x = Signal.make(0.);
	public final y = Signal.make(0.);
	public final markerX = Signal.make(0.);
	public final markerY = Signal.make(0.);
	public final markerHeight = Signal.make(0.);
	public final snapshot = Signal.make((null : EditorTabSnapshot));

	final groups:EditorGroups;
	final select:(EditorGroup, String) -> Void;
	final drop:(String, EditorGroup, Null<Int>) -> Void;
	final panes = new Map<Int, Element>();
	var gesture:Null<Gesture>;
	var destination:Null<Drop>;
	var tree:Null<LayoutTree>;
	var pointerHook:Null<LayoutTree->Void>;
	var flushHook:Null<LayoutTree->Void>;
	var captureHook:Null<LayoutTree->Void>;
	var scrollTimer:Null<ashui.animation.AnimationScheduler.Timer>;
	var suppressed = false;

	public function new(groups:EditorGroups, select:(EditorGroup, String) -> Void, drop:(String, EditorGroup, Null<Int>) -> Void) {
		this.groups = groups;
		this.select = select;
		this.drop = drop;
	}

	public function register(group:EditorGroup, pane:Element):Void->Void {
		panes.set(group.id, pane);
		return () -> {
			if (panes.get(group.id) == pane)
				panes.remove(group.id);
			if (gesture != null && gesture.pane == pane)
				cancel();
		};
	}

	/** Close buttons keep their normal press/release behavior. */
	public function begin(group:EditorGroup, path:String, event:PointerEvent):Void {
		if (event.button == null || !event.button.match(Left))
			return;
		cancel();
		suppressed = false;
		for (id in [event.target.id].concat(event.target.tree.ancestors(event.target.id))) {
			var identity = Identity.of(event.target.tree, id);
			if (identity != null && identity.hasClass("rayde-close"))
				return;
		}
		var pane = panes.get(group.id);
		if (pane == null || groups.owner(path) != group)
			return;
		tree = pane.tree;
		gesture = {
			source: group,
			pane: pane,
			file: path,
			x: event.x,
			y: event.y,
			started: false
		};
		pointerHook = current -> {
			if (current == tree)
				update();
		};
		flushHook = current -> {
			if (current == tree && gesture != null)
				update();
		};
		Pointer.hooks.push(pointerHook);
		LayoutTree.flushHooks.push(flushHook);
	}

	public function suppressClick():Bool
		return suppressed;

	public function key(event:KeyEvent):Bool {
		if (gesture == null || !event.key.match(Named(Escape)))
			return false;
		suppressed = true;
		cancel();
		event.preventDefault();
		event.stopPropagation();
		return true;
	}

	public function cancel():Void {
		gesture = null;
		destination = null;
		if (scrollTimer != null)
			scrollTimer.cancel();
		scrollTimer = null;
		if (pointerHook != null)
			removeHook(Pointer.hooks, pointerHook);
		pointerHook = null;
		if (flushHook != null)
			removeHook(LayoutTree.flushHooks, flushHook);
		flushHook = null;
		if (captureHook != null)
			removeHook(LayoutTree.settledHooks, captureHook);
		captureHook = null;
		var image = snapshot.get();
		if (image != null) {
			image.dispose();
			snapshot.set(null);
		}
		tree = null;
		if (file.get() != "")
			file.set("");
		if (target.get() != -1)
			target.set(-1);
		if (markerHeight.get() != 0)
			markerHeight.set(0);
	}

	static function removeHook(hooks:Array<LayoutTree->Void>, hook:LayoutTree->Void):Void {
		for (i in 0...hooks.length)
			if (Reflect.compareMethods(hooks[i], hook)) {
				hooks.splice(i, 1);
				return;
			}
	}

	function update():Void {
		var drag = gesture;
		if (drag == null)
			return;
		if (groups.owner(drag.file) != drag.source || panes.get(drag.source.id) != drag.pane) {
			cancel();
			return;
		}
		var point = Pointer.at(tree);
		if (!point.inside) {
			cancel();
			return;
		}
		if (!point.pressed) {
			var into = drag.started ? hit(point.x, point.y) : null;
			cancel();
			if (into != null)
				drop(drag.file, into.group, into.index);
			return;
		}
		if (!drag.started) {
			var dx = point.x - drag.x, dy = point.y - drag.y;
			if (dx * dx + dy * dy < 36)
				return;
			drag.started = true;
			suppressed = true;
			file.set(drag.file);
			select(drag.source, drag.file);
			captureHook = current -> {
				if (current != tree)
					return;
				removeHook(LayoutTree.settledHooks, captureHook);
				captureHook = null;
				try
					snapshot.set(EditorTabSnapshot.capture(drag.pane))
				catch (error:Dynamic)
					trace('Tab thumbnail: $error');
			};
			LayoutTree.settledHooks.push(captureHook);
		}
		if (x.get() != point.x)
			x.set(point.x);
		if (y.get() != point.y)
			y.set(point.y);
		destination = hit(point.x, point.y);
		var next = destination == null ? -1 : destination.group.id;
		if (target.get() != next)
			target.set(next);
		var height = destination == null || destination.index == null ? 0. : destination.height;
		if (markerHeight.get() != height)
			markerHeight.set(height);
		if (height > 0) {
			if (markerX.get() != destination.marker)
				markerX.set(destination.marker);
			if (markerY.get() != destination.top)
				markerY.set(destination.top);
		}
		if (destination != null && destination.edge != 0 && scrollTimer == null) {
			scrollTimer = AnimationScheduler.main.after(1 / 60, autoScroll);
		} else if ((destination == null || destination.edge == 0) && scrollTimer != null) {
			scrollTimer.cancel();
			scrollTimer = null;
		}
	}

	function autoScroll():Void {
		scrollTimer = null;
		var into = destination;
		if (gesture == null || into == null || into.scroll == null || into.edge == 0)
			return;
		into.scroll.scrollTo(into.scroll.x.get() + into.edge * 14, 0);
		update();
	}

	static function contains(box:Null<Bounds>, px:Float, py:Float):Bool
		return box != null && box.width > 0 && box.height > 0 && px >= box.x && px < box.x + box.width && py >= box.y && py < box.y + box.height;

	function hit(px:Float, py:Float):Null<Drop> {
		var chain = tree.hitTest(px, py);
		for (group in groups.all()) {
			var pane = panes.get(group.id);
			if (pane == null
				|| !contains(tree.getScrolledBounds(pane.node), px, py)
				|| !Lambda.exists(chain, hit -> hit.id == pane.node.id))
				continue;
			var result:Drop = {
				group: group,
				index: null,
				marker: 0,
				top: 0,
				height: 0,
				scroll: null,
				edge: 0
			};
			var strips = Css.query(tree, pane.node.id, "#rayde-tab-scroll");
			if (strips.length == 0)
				return result;
			var node = new Node(strips[0]), box = tree.getScrolledBounds(node);
			if (box == null || py < box.y || py >= box.y + box.height)
				return result;
			var tabs = Css.query(tree, node.id, ".rayde-tab"), slot = 0, position = box.x;
			for (id in tabs) {
				if (Identity.of(tree, id).attribute("data-tab-file") == gesture.file)
					continue;
				var tab = tree.getScrolledBounds(new Node(id));
				if (tab == null)
					continue;
				if (px < tab.x + tab.width / 2) {
					position = tab.x;
					break;
				}
				slot++;
				position = tab.x + tab.width;
			}
			result.index = slot;
			result.marker = Math.max(box.x, Math.min(box.x + box.width - 2, position));
			result.top = box.y + 4;
			result.height = box.height - 4;
			result.scroll = Scroll.at(node.id, tree);
			if (result.scroll != null) {
				var offset = result.scroll.x.get(),
					limit = result.scroll.limits().x;
				if (px < box.x + 24 && offset > 0)
					result.edge = -1;
				else if (px >= box.x + box.width - 24 && offset < limit)
					result.edge = 1;
			}
			return result;
		}
		return null;
	}
}
