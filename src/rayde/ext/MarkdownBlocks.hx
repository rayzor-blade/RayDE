package rayde.ext;

import ashui.css.Identity;
import ashui.input.Scroll;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.layout.Prop;
import ashui.reactive.Owner;
import ashui.ui.Div;

private typedef MountedBlock = {owner:Owner, view:Div};

/** Variable-height document blocks; only viewport neighbors own native views. */
class MarkdownBlocks {
	public final node:ashui.layout.Node;
	final body:Div;
	final scope:Owner;
	final data:Array<Dynamic>;
	final render:(Dynamic, Int)->Element;
	final estimate:(Dynamic, Float)->Float;
	final key:Dynamic;
	final keys:Array<String>;
	final mounted:Map<Int, MountedBlock> = [];
	var heights:Array<Float>;
	var offsets:Array<Float> = [];
	var width:Float;
	var first = 0;
	var last = -1;
	var timer:ashui.animation.AnimationScheduler.Timer;
	var requested:Null<{x:Float, y:Float}>;
	var target = -1;
	var revealTarget:Null<Void->Bool>;
	var alive = true;
	var observed:Scroll;
	var origin = 0.;
	var viewportHeight = 600.;
	var scrollX = 0.;
	var scrollY = 0.;
	static inline var GAP = 16.;
	static inline var OVERSCAN = 120.;

	public function new(data:Array<Dynamic>, render:(Dynamic, Int)->Element, estimate:(Dynamic, Float)->Float, identify:Dynamic->String, key:Dynamic, saved:Dynamic) {
		this.data = data; this.render = render; this.estimate = estimate; this.key = key;
		scope = Owner.current;
		body = new Div({position:ashui.types.Style.Position.Relative, flexShrink:0, minWidth:0});
		node = body.node;
		node.set(Prop.WidthPercent, (1:Single));
		Identity.of(body.tree, node.id).setClasses(["rayde-md-blocks"]);
		var cache:Dynamic = saved == null ? null : saved.layout;
		var reusable = cache != null && cache.key == key && cache.heights != null && (cache.heights:Array<Float>).length == data.length;
		width = reusable ? cache.width : 776.;
		keys = reusable ? cache.keys : [for (block in data) identify(block)];
		var old:Map<String, Float> = [];
		if (!reusable && cache != null && cache.keys != null) {
			width = cache.width;
			var previous:Array<String> = cache.keys, sizes:Array<Float> = cache.heights;
			for (i in 0...previous.length) old.set(previous[i], sizes[i]);
		}
		heights = reusable ? (cache.heights:Array<Float>).copy() : [for (i in 0...data.length) old.exists(keys[i]) ? old.get(keys[i]) : estimate(data[i], width)];
		if (saved != null) requested = {x:saved.x, y:saved.y};
		if (saved != null) { scrollX = saved.x; scrollY = saved.y; }
		positions();
		choose(requested == null ? 0 : requested.y, 600);
		sync();
		LayoutTree.settledHooks.push(layout);
		Owner.onCleanup(() -> {
			alive = false;
			if (timer != null) timer.cancel();
			LayoutTree.settledHooks.remove(layout);
			mounted.clear(); revealTarget = null;
		});
	}

	function positions():Void {
		offsets = [0.];
		for (h in heights) offsets.push(offsets[offsets.length-1] + h + GAP);
		node.set(Prop.Height, (Math.max(0, offsets[offsets.length-1] - GAP):Single));
		for (i => block in mounted) block.view.node.set(Prop.Top, (offsets[i]:Single));
	}

	function at(y:Float):Int {
		var lo = 0, hi = data.length;
		while (lo < hi) {
			var middle = (lo + hi) >> 1;
			if (offsets[middle+1] <= y) lo = middle + 1; else hi = middle;
		}
		return Std.int(Math.min(Math.max(0, data.length-1), lo));
	}

	function choose(y:Float, height:Float):Void {
		first = at(Math.max(0, y - OVERSCAN)); last = data.length == 0 ? -1 : at(y + height + OVERSCAN);
		if (target >= 0) { first = Std.int(Math.min(first, target)); last = Std.int(Math.max(last, target)); }
	}

	function queue():Void {
		if (timer != null || !alive) return;
		timer = ashui.animation.AnimationScheduler.main.after(.001, () -> {
			timer = null;
			if (alive) scope.run(sync);
		});
	}

	function sync():Void {
		var start = haxe.Timer.stamp();
		for (i in [for (i in mounted.keys()) if (i < first || i > last) i]) {
			mounted.get(i).owner.dispose(); mounted.remove(i);
		}
		var built = 0;
		for (i in first...last+1) if (!mounted.exists(i)) {
			if (built > 0 && (built >= 4 || haxe.Timer.stamp()-start > .006)) { queue(); break; }
			var owner = new Owner(body.tree);
			var view = owner.run(() -> {
				var block = new Div({position:ashui.types.Style.Position.Absolute, left:0, top:offsets[i], minWidth:0, flexDirection:ashui.types.Style.FlexDirection.Column, flexShrink:0});
				block.node.set(Prop.WidthPercent, (1:Single));
				Identity.of(body.tree, block.node.id).setClasses(["rayde-md-block"]).setAttribute("data-md-block", Std.string(i));
				block.appendChild(render(data[i], i)); body.appendChild(block);
				return block;
			});
			mounted.set(i, {owner:owner, view:view}); built++;
		}
	}

	function scroll():Null<Scroll> {
		for (id in body.tree.ancestors(node.id)) { var s = Scroll.at(id, body.tree); if (s != null) return s; }
		return null;
	}

	function layout(tree:LayoutTree):Void {
		if (!alive || tree != body.tree) return;
		var s = scroll(), bounds = tree.getScrolledBounds(node);
		if (s == null || bounds == null || bounds.width <= 0) return;
		var viewport = tree.getScrolledBounds(s.node);
		if (viewport == null || viewport.height <= 0) return;
		origin = viewport.y-bounds.y-s.y.get(); viewportHeight = viewport.height;
		if (observed == null) {
			observed = s;
			scope.run(() -> new ashui.reactive.Watch(() -> ({x:s.x.get(), y:s.y.get()}), position -> {
				scrollX = position.x; scrollY = position.y;
				var a = first, b = last;
				choose(Math.max(0, position.y+origin), viewportHeight);
				if (a != first || b != last) queue();
			}));
		}
		if (requested != null) {
			var next = requested; requested = null;
			var limits = s.limits();
			next = {x:Math.min(next.x, limits.x), y:Math.min(next.y, limits.y)};
			if (Math.abs(s.x.get()-next.x) > .5 || Math.abs(s.y.get()-next.y) > .5) { s.jumpTo(next.x, next.y); return; }
		}
		var limits = s.limits();
		if (s.y.get() > limits.y + .5) { s.jumpTo(s.x.get(), limits.y); return; }
		var y = Math.max(0, viewport.y-bounds.y), anchor = at(y), oldTop = offsets[anchor], changed = false;
		if (Math.abs(width-bounds.width) > .5) {
			width = bounds.width;
			for (i in 0...data.length) heights[i] = estimate(data[i], width);
			changed = true;
		}
		for (i => block in mounted) {
			var b = tree.getBounds(block.view.node);
			if (b != null && b.height > 0 && Math.abs(heights[i]-b.height) > .5) { heights[i] = b.height; changed = true; }
		}
		if (changed) {
			positions();
			if (Math.abs(offsets[anchor]-oldTop) > .5) requested = {x:s.x.get(), y:Math.max(0,s.y.get()+offsets[anchor]-oldTop)};
			return;
		}
		if (revealTarget != null && mounted.exists(target) && revealTarget()) { revealTarget = null; target = -1; }
		choose(y, viewport.height);
		var complete = true;
		for (i in first...last+1) if (!mounted.exists(i)) complete = false;
		for (i in mounted.keys()) if (i < first || i > last) complete = false;
		Identity.of(tree, node.id).setAttribute("data-md-ready", complete ? "true" : null);
		if (!complete) queue();
	}

	public function reveal(index:Int, finish:Void->Bool):Void {
		target = index; revealTarget = finish;
		var s = scroll();
		if (s != null) { requested = {x:s.x.get(), y:offsets[index]}; s.jumpTo(s.x.get(), offsets[index]); }
		choose(offsets[index], 600); queue();
	}

	public function state():Dynamic return {key:key, keys:keys, width:width, heights:heights.copy()};
	public function navigation():{x:Float, y:Float} return {x:scrollX, y:scrollY};
}
