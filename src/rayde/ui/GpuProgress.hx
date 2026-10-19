package rayde.ui;

import ashui.animation.AnimationScheduler;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import gpu.GpuDevice;

/** Services completed native GPU work, including releases after a frame's garbage collection. */
class GpuProgress {
	public static function attach(device:GpuDevice, tree:LayoutTree, frames:Void->Int):Void {
		var timer:Null<ashui.animation.AnimationScheduler.Timer> = null, remaining = 0, lastFrame = -1;
		var poll:Void->Void = null;
		poll = () -> {
			timer = null;
			device.poll();
			if (--remaining > 0) timer = AnimationScheduler.main.after(.05, poll);
		};
		var flush:LayoutTree->Void = current -> {
			if (current != tree) return;
			device.poll();
			var frame = frames();
			if (frame == lastFrame) return;
			lastFrame = frame; remaining = 6;
			if (timer == null) timer = AnimationScheduler.main.after(.05, poll);
		};
		LayoutTree.flushHooks.push(flush);
		Owner.onCleanup(() -> {
			if (timer != null) timer.cancel();
			for (i in 0...LayoutTree.flushHooks.length) if (Reflect.compareMethods(LayoutTree.flushHooks[i], flush)) { LayoutTree.flushHooks.splice(i, 1); break; }
		});
	}
}
