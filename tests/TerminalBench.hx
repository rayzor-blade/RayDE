import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.theme.ThemeState;
import ashui.theme.themes.RestrainedTheme;
import gpu.GpuTextureViewDescriptor;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

/**
 * The terminal under a program that fills the screen as fast as it can: each
 * frame is the poll that fetches the changed rows, the layout, the canvas's
 * drawing and its encoding, with the screen entirely new each time. Costs are
 * in milliseconds a frame; a display refresh is 16.7 at 60 Hz and 8.3 at 120.
 */
class TerminalBench {
	static inline var WIDTH = 1280;
	static inline var HEIGHT = 800;
	static inline var FRAMES = 120;

	static function main():Void {
		var root = Sys.getCwd() + "tests/fixtures/basic", server = new CompilerServer();
		ThemeState.init(RestrainedTheme.bundle(), Dark);
		rayde.ui.Style.use();
		var display = Display.ofHxml(server, root + "/build.hxml"), tree = new LayoutTree(), bench:Workbench = null;
		var view = Owner.root(tree, _ -> bench = new Workbench({display: display, name: "basic", runtime: "ash"}));
		function frame():Void {
			Offscreen.advance(1 / 60);
			Css.setViewport(WIDTH, HEIGHT);
			Css.update();
			tree.flush();
			tree.computeLayout(view.node, WIDTH, HEIGHT);
		}
		for (_ in 0...5)
			frame();
		var colourful = "\\033[31mred \\033[1;32mgreen\\033[0m plain text with some more words to fill the line out \\033[38;5;208morange\\033[0m \\033[4munder\\033[0m \\033[7minv\\033[0m end";
		bench.terminalPart.terminalProgram = "/bin/sh";
		bench.terminalPart.terminalArgs = ["-c", 'while :; do printf "$colourful\\n"; done'];
		bench.showPanel("terminal");
		bench.panelsPart.setPanelHeight(560);
		var wait = haxe.Timer.stamp() + 8;
		while ((bench.terminalPart.terminal() == null || bench.terminalPart.terminal().line(10).indexOf("orange") < 0) && haxe.Timer.stamp() < wait) {
			Sys.sleep(.03);
			frame();
		}
		var offscreen = Snapshot.renderer(), texture = offscreen.createTexture(WIDTH, HEIGHT), target = texture.createView(new GpuTextureViewDescriptor());
		var update:Array<Float> = [], encode:Array<Float> = [];
		for (i in 0...FRAMES) {
			// A real frame is 16 ms apart, in which the program prints more.
			Sys.sleep(.016);
			var a = haxe.Timer.stamp();
			frame();
			var b = haxe.Timer.stamp();
			offscreen.renderTree(tree, view.node, target, WIDTH, HEIGHT);
			var c = haxe.Timer.stamp();
			if (i >= 10) {
				update.push((b - a) * 1000);
				encode.push((c - b) * 1000);
			}
		}
		var screen = bench.terminalPart.terminal().screen();
		Sys.println('terminal ${screen.cols} x ${screen.rows}, ${offscreen.primitives} primitives in the last frame');
		report("poll, layout", update);
		report("encode", encode);
		report("total", [for (i in 0...update.length) update[i] + encode[i]]);
		bench.terminalPart.killTerminal();
		target.destroy();
		texture.destroy();
		tree.dispose();
		server.stop();
	}

	static function report(what:String, values:Array<Float>):Void {
		var sorted = values.copy();
		sorted.sort(Reflect.compare);
		inline function at(p:Float):Float
			return sorted[Std.int(Math.min(sorted.length - 1, Math.floor(sorted.length * p)))];
		Sys.println(StringTools.rpad(what, " ", 14) + 'median ${f(at(.5))}  p95 ${f(at(.95))}  worst ${f(sorted[sorted.length - 1])} ms');
	}

	static function f(v:Float):String
		return Std.string(Math.round(v * 10) / 10);
}
