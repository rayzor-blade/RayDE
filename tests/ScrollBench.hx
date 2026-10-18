import ashui.components.CodeEditor;
import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.input.Scroll;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.theme.ThemeState;
import ashui.theme.themes.RestrainedTheme;
import gpu.GpuTextureViewDescriptor;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

/**
 * A long file open in the workbench, flicked and left to decelerate, with what
 * each frame costs: laying the moved tree out, encoding the draw, and (reading
 * the pixels back, which waits for the GPU) finishing it. A frame that takes
 * longer than the display's interval is a visible drop, so the 95th percentile
 * and the worst frame matter more than the median. `ROWS` sets the file's
 * length in functions of ten lines; the default is 400.
 */
class ScrollBench {
	static inline var WIDTH = 1280;
	static inline var HEIGHT = 800;
	static var FRAMES = 150;

	static function main():Void {
		// DRIFT=<n> scrolls n frames at 2.4 px a frame instead of the flick: the pace of a flick's tail, for profiling it.
		var drift = Std.parseInt(Sys.getEnv("DRIFT"));
		if (drift != null)
			FRAMES = drift;
		var rows = Std.parseInt(Sys.getEnv("ROWS"));
		var root = project(rows == null ? 400 : rows), server = new CompilerServer();
		ThemeState.init(RestrainedTheme.bundle(), Dark);
		rayde.ui.Style.use();
		// ALONE=<flags> puts the editor by itself, without the workbench: each of g (gutter numbers), f (folding), i (indent guides)
		// and b (bracket matching) in the flags turns that feature on, so a feature's cost can be told by leaving it out.
		var alone = Sys.getEnv("ALONE"), text = sys.io.File.getContent(root + "/src/Main.hx");
		var display = Display.ofHxml(server, root + "/build.hxml"), tree = new LayoutTree(), bench:Workbench = null;
		var view = Owner.root(tree, _ -> Sys.getEnv("PLAIN") != null ? scroller(Std.parseInt(Sys.getEnv("PLAIN"))) : alone != null ? plain(text, alone) : bench = new Workbench({display: display, name: "large", runtime: "ash"}));
		function settle(frames:Int):Void
			for (_ in 0...frames) {
				Offscreen.advance(1 / 60);
				Css.setViewport(WIDTH, HEIGHT);
				Css.update();
				tree.flush();
				tree.computeLayout(view.node, WIDTH, HEIGHT);
			}
		settle(5);
		if (bench != null)
			bench.openFile(root + "/src/Main.hx");
		settle(30);
		var viewport = Css.query(tree, view.node.id, Sys.getEnv("PLAIN") != null ? "#scroller" : ".ui-code-viewport")[0];
		var scroll = Scroll.at(viewport, tree);
		if (scroll == null)
			throw "the editor has no scroll viewport";
		var offscreen = Snapshot.renderer(), texture = offscreen.createTexture(WIDTH, HEIGHT), target = texture.createView(new GpuTextureViewDescriptor());
		var layout:Array<Float> = [], encode:Array<Float> = [], finish:Array<Float> = [];
		// Where the layout time goes, a row for each frame: moving the scroll, the stylesheet, the flush of changes, and the layout itself.
		var parts:Array<Array<Float>> = [];
		// A flick of 9000 px/s that slows with a time constant of half a second, one step a display refresh.
		var y = 0.;
		for (i in 0...FRAMES) {
			var t = i / 60;
			var next = drift != null ? (Math.isNaN(Std.parseFloat(Sys.getEnv("STEP"))) ? 2.4 : Std.parseFloat(Sys.getEnv("STEP"))) * i : 9000 * 0.5 * (1 - Math.exp(-t / 0.5));
			var a = haxe.Timer.stamp();
			var before = y;
			scroll.scrollTo(0, next);
			y = next;
			var a1 = haxe.Timer.stamp();
			Offscreen.advance(1 / 60);
			Css.update();
			var a2 = haxe.Timer.stamp();
			tree.flush();
			var a3 = haxe.Timer.stamp();
			tree.computeLayout(view.node, WIDTH, HEIGHT);
			var b = haxe.Timer.stamp();
			offscreen.renderTree(tree, view.node, target, WIDTH, HEIGHT);
			var c = haxe.Timer.stamp();
			offscreen.readRgba8(texture, WIDTH, HEIGHT);
			var d = haxe.Timer.stamp();
			if (i >= 10) {
				parts.push([next - before, (a1 - a) * 1000, (a2 - a1) * 1000, (a3 - a2) * 1000, (b - a3) * 1000]);
				layout.push((b - a) * 1000);
				encode.push((c - b) * 1000);
				finish.push((d - c) * 1000);
			}
		}
		target.destroy();
		texture.destroy();
		Sys.println('scrolled ${Std.int(y)} px of a ${text.split("\n").length}-line file; ${offscreen.primitives} primitives in the last frame');
		// The flick's fast start, its middle and its slow tail, by the size of the step: median of each part of a frame in each third.
		var third = Std.int(parts.length / 3);
		for (k => name in ["fast", "middle", "tail"]) {
			var slice = parts.slice(k * third, (k + 1) * third);
			function med(col:Int):Float {
				var v = [for (r in slice) r[col]];
				v.sort(Reflect.compare);
				return v[Std.int(v.length / 2)];
			}
			Sys.println(StringTools.rpad(name, " ", 8) + 'step ${f(med(0))} px   scroll ${f(med(1))}  css ${f(med(2))}  flush ${f(med(3))}  layout ${f(med(4))} ms');
		}
		report("layout", layout);
		report("encode", encode);
		report("finish", finish);
		report("total", [for (i in 0...layout.length) layout[i] + encode[i] + finish[i]]);
		tree.dispose();
		server.stop();
	}

	/** A scroll view of `rows` rows of eight words each and nothing else, to tell what scrolling costs apart from the editor. */
	static function scroller(rows:Int):ashui.layout.Element {
		var content = [for (i in 0...rows) row(i)];
		return <div class="flex flex-col" widthPercent={1} heightPercent={1}>
			<div id="scroller" class="flex flex-col overflow-auto" height={700}>{content}</div>
		</div>;
	}

	static function row(i:Int):ashui.layout.Element {
		var words = [for (w in 0...8) <text class="text-sm">${"word" + i + "_" + w}</text>];
		return <div class="flex gap-2" height={21}>{words}</div>;
	}

	static function plain(text:String, flags:String):ashui.layout.Element {
		var on = (c:String) -> flags.indexOf(c) >= 0;
		return <div class="flex flex-col" widthPercent={1} heightPercent={1}>
			<code-editor id="alone" value={text} language="haxe" lineNumbers={on("g")} folding={on("f")} indentGuides={on("i")} highlightBrackets={on("b")}
				tabSize={4} insertSpaces={false} class="flex-1 min-h-0"/>
		</div>;
	}

	static function report(what:String, values:Array<Float>):Void {
		var sorted = values.copy();
		sorted.sort(Reflect.compare);
		inline function at(p:Float):Float
			return sorted[Std.int(Math.min(sorted.length - 1, Math.floor(sorted.length * p)))];
		Sys.println(StringTools.rpad(what, " ", 8) + 'median ${f(at(.5))}  p95 ${f(at(.95))}  worst ${f(sorted[sorted.length - 1])} ms');
	}

	static function f(v:Float):String
		return Std.string(Math.round(v * 10) / 10);

	/** A project of one file of `functions` functions, ten lines each, under bin/fixtures/large. */
	static function project(functions:Int):String {
		var dir = Sys.getCwd() + "bin/fixtures/large";
		sys.FileSystem.createDirectory(dir);
		sys.FileSystem.createDirectory(dir + "/src");
		sys.io.File.saveContent(dir + "/build.hxml", "-cp src\n--main Main\n");
		var out = new StringBuf();
		out.add("class Main {\n");
		for (n in 0...functions) {
			out.add('\t/** Adds the first ${n + 1} numbers, as function $n of the file. */\n');
			out.add('\tstatic function sum$n(limit:Int):Int {\n\t\tvar total = 0;\n\t\tfor (i in 0...limit) {\n');
			out.add('\t\t\tif (i % 2 == 0)\n\t\t\t\ttotal += i * $n;\n\t\t\telse\n\t\t\t\ttotal -= i;\n');
			out.add("\t\t}\n\t\treturn total;\n\t}\n\n");
		}
		out.add("\tstatic function main() {\n\t\ttrace(sum0(10));\n\t}\n}\n");
		sys.io.File.saveContent(dir + "/src/Main.hx", out.toString());
		return dir;
	}
}
