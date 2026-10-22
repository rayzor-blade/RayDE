import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.theme.ThemeState;
import ashui.theme.themes.RestrainedTheme;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

/** Frame-stage timings around panel transitions; no image readback or server dependency. */
@:access(rayde.ui.Workbench)
class PanelLatencyProbe {
	static function main():Void {
		var root = Sys.getCwd() + "bin/panel-latency-workspace";
		sys.FileSystem.createDirectory(root + "/src");
		sys.FileSystem.createDirectory(root + "/empty-extensions");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/empty-extensions");
		sys.io.File.saveContent(root + "/build.hxml", "-cp src\n-main Main\n");
		var file = root + "/src/Main.hx";
		sys.io.File.saveContent(file, "class Main {\n" + [for(i in 0...2000) ' static var value$i:Int = $i;'].join("\n") + "\n static function main() {}\n}\n");
		ThemeState.init(RestrainedTheme.bundle(), Dark); rayde.ui.Style.use();
		var compiler = new CompilerServer(), tree = new LayoutTree(), stop:Void->Void = null;
		var bench = Owner.root(tree, cleanup -> { stop = cleanup; return new Workbench({display:Display.ofHxml(compiler, root + "/build.hxml"), name:"Panel latency", runtime:"ash"}); });
		bench.terminalProgram = "/bin/sh"; bench.terminalArgs = ["-c", "printf 'ready\\n'; read value"];
		var renderer = Snapshot.renderer(), texture = renderer.createTexture(1280,800), target = texture.createView(new gpu.GpuTextureViewDescriptor());
		var last = haxe.Timer.stamp();
		function frame():Dynamic {
			var times:Dynamic = {}, started = haxe.Timer.stamp(), mark = started;
			function stage(name:String, action:Void->Void) { action(); var now = haxe.Timer.stamp(); Reflect.setField(times,name,(now-mark)*1000); mark=now; }
			var now = haxe.Timer.stamp(), elapsed = now-last; last=now;
			stage("timers", () -> ashui.animation.AnimationScheduler.main.tick(Math.min(.1,elapsed),elapsed));
			stage("css", () -> { ThemeState.get().tick(); Css.update(); });
			stage("flush", () -> tree.flush());
			stage("layout", () -> tree.computeLayout(bench.node,1280,800));
			stage("draw", () -> renderer.renderTree(tree,bench.node,target,1280,800));
			stage("gc", () -> ashui.core.Memory.afterFrame());
			times.total=(haxe.Timer.stamp()-started)*1000; return times;
		}
		function settle(count=8) { for(_ in 0...count) { frame(); Sys.sleep(.005); } }
		bench.openFile(file); settle(30);
		var count = Std.parseInt(Sys.getEnv("RAYDE_PANEL_PROBLEMS") ?? "200");
		bench.problems.set([for(i in 0...count) {file:file,severity:1,message:'Problem $i',range:{start:{line:i%2000,character:0},end:{line:i%2000,character:1}}}]);
		bench.consoleText.set([for(i in 0...10000) 'Output line $i with content to measure.'].join("\n"));
		settle(20);
		for(cycle in 0...3) for(tab in ["problems","console","terminal"]) for(open in [true,false]) {
			var before=hl.Gc.stats().totalAllocated, at=haxe.Timer.stamp();
			if(open) bench.showPanel(tab); else bench.closePanel();
			var call=(haxe.Timer.stamp()-at)*1000, frames=[];
			for(_ in 0...10) { frames.push(frame()); Sys.sleep(.005); }
			Sys.println("panel-latency:"+haxe.Json.stringify({cycle:cycle,tab:tab,open:open,call:call,frames:frames,
				allocated:hl.Gc.stats().totalAllocated-before,nodes:tree.order().length,rows:Css.query(tree,bench.node.id,".rayde-problem").length})); Sys.stdout().flush();
		}
		stop(); compiler.stop(); tree.dispose(); target.destroy(); texture.destroy();
	}
}
