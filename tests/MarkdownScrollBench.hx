import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.input.Pointer;
import ashui.input.Scroll;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.theme.ThemeState;
import ashui.theme.themes.RestrainedTheme;
import rayde.ext.MarkdownView;

/** Continuous phased wheel gestures through variable-height Markdown, including the slow tail and reversals. */
class MarkdownScrollBench {
	static function main():Void {
		ThemeState.init(RestrainedTheme.bundle(), Sys.getEnv("LIGHT") == "1" ? Light : Dark);
		rayde.ui.Style.use();
		var parts:Array<Dynamic> = [];
		for (i in 0...250) parts.push({kind:"paragraph", children:[{kind:"text", text:'Paragraph $i. ' + [for (n in 0...12+i%8*7) "Scrolling through variable height blocks."].join(" ")}]});
		var tree = new LayoutTree(), markdown:MarkdownView = null;
		var view = Owner.root(tree, _ -> {
			markdown = new MarkdownView(Signal.make(({children:parts}:Dynamic)), (_, _) -> {});
			var root = <div id="rayde" class="flex flex-col overflow-auto" widthPercent={1} heightPercent={1}/>;
			tree.addChild(root.node.id, markdown.node.id);
			return root;
		});
		var renderer = Snapshot.renderer(), texture = renderer.createTexture(900, 700);
		var target = texture.createView(new gpu.GpuTextureViewDescriptor());
		var stages:Array<Float> = [];
		function frame():Void {
			var a = haxe.Timer.stamp();
			Offscreen.advance(1/60); Css.setViewport(900, 700); Css.update();
			var b = haxe.Timer.stamp();
			tree.flush(); tree.computeLayout(view.node, 900, 700);
			var c = haxe.Timer.stamp();
			renderer.renderTree(tree, view.node, target, 900, 700);
			var d = haxe.Timer.stamp();
			ashui.core.Memory.afterFrame();
			stages = [(b-a)*1000, (c-b)*1000, (d-c)*1000, (haxe.Timer.stamp()-d)*1000];
		}
		for (_ in 0...40) frame();
		var scroll = Scroll.of(view.node), records:Array<Dynamic> = [];
		if (scroll.limits().y < 10000) throw "Markdown scroll fixture has no content extent";
		Pointer.move(tree, 850, 350);
		for (phase in ["down", "up", "tail", "cold-up"]) {
			if (phase == "cold-up") { scroll.jumpTo(0, 35000); for (_ in 0...40) frame(); }
			for (i in 0...150) {
				var blocks = @:privateAccess markdown.blocks;
				var anchor = @:privateAccess blocks.mounted.get(blocks.at(Math.max(0, scroll.y.get()+blocks.origin)));
				var oldY = anchor == null ? 0 : tree.getScrolledBounds(anchor.view.node).y;
				var step = phase == "tail" ? 2.4 : (phase == "up" || phase == "cold-up" ? -1 : 1) * 150 * Math.exp(-i/70);
				var start = haxe.Timer.stamp(), before = scroll.y.get();
				Pointer.wheel(tree, 0, -step, i == 0 ? Started : Moved);
				var requested = scroll.y.get();
				frame();
				var ms = (haxe.Timer.stamp()-start)*1000;
				var y = scroll.y.get(), missing = 0, count = 0;
				var anchorError = anchor == null || anchor.view.node == null ? 0 : tree.getScrolledBounds(anchor.view.node).y-oldY+requested-before;
				@:privateAccess {
					for (j in blocks.mounted.keys()) count++;
					var top = Math.max(0, y+blocks.origin), bottom = top+700;
					for (j in blocks.at(top)...blocks.at(bottom)+1) if (!blocks.mounted.exists(j)) missing++;
				}
				records.push({phase:phase, frame:i, ms:ms, stages:stages, y:y, input:requested-before, correction:y-requested, anchorError:anchorError, mounted:count, missing:missing});
			}
			Pointer.wheel(tree, 0, 0, Ended);
		}
		Sys.println("markdown-scroll:" + haxe.Json.stringify(records));
		for (phase in ["down", "up", "tail", "cold-up"]) {
			var samples = records.filter(r -> r.phase == phase), times = samples.map(r -> (r.ms:Float));
			times.sort(Reflect.compare);
			var missing = Lambda.count(samples, r -> r.missing != 0);
			var jumps = Lambda.count(samples, r -> Math.abs(r.anchorError) > .5);
			var travel = Lambda.fold(samples, (r, sum) -> sum+(r.input:Float), 0.);
			Sys.println('markdown-scroll-summary: ' + haxe.Json.stringify({phase:phase, medianMs:times[75], p95Ms:times[142], worstMs:times[149], missingFrames:missing, anchorJumps:jumps}));
			if (phase == "tail" ? Math.abs(travel-360) > .5 : Math.abs(travel) < 8000) throw 'wheel gesture did not move the Markdown viewport at $phase';
			if (missing != 0 || jumps != 0 || Lambda.exists(samples, r -> r.mounted > 16)) throw 'unbounded or discontinuous Markdown scrolling at $phase';
		}
		for (_ in 0...30) frame();
		Snapshot.capture("markdown-scroll", tree, view.node, 900, 700, 0x0d1117);
		target.destroy(); texture.destroy(); tree.dispose();
	}
}
