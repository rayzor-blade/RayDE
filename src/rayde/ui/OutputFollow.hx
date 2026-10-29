package rayde.ui;

import ashui.components.CodeView;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;

/** One channel's follow preference survives disposal of its Output view. */
class OutputFollow {
	var following = true;

	public function new() {}

	public function attach(view:CodeView):Void {
		var ready = false, live = true, lastY = 0., lastLimit = 0.;
		var layout:LayoutTree->Bool = tree -> {
			if (!live || tree != view.tree) return false;
			var scroll = view.scroll, bounds = tree.getBounds(scroll.node);
			if (bounds == null || bounds.width <= 0 || bounds.height <= 0) return false;
			var y = scroll.y.get(), limit = scroll.limits().y;
			// New text changes the extent without moving the reader. Compare a
			// moved offset with the previous end, allowing for a shorter log.
			if (ready && Math.abs(y - lastY) > .5) following = y >= Math.min(lastLimit, limit) - 1;
			if (limit <= 1) following = true;
			ready = true;
			var moved = following && scroll.scrollTo(scroll.x.get(), limit);
			lastY = scroll.y.get(); lastLimit = limit;
			return moved;
		};
		LayoutTree.layoutHooks.push(layout);
		Owner.onCleanup(() -> {
			live = false;
			for (i in 0...LayoutTree.layoutHooks.length)
				if (Reflect.compareMethods(LayoutTree.layoutHooks[i], layout)) { LayoutTree.layoutHooks.splice(i, 1); break; }
		});
	}
}
