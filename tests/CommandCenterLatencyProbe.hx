import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.theme.ThemeState;
import ashui.theme.themes.RestrainedTheme;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

/** Command center frame timings in a code workspace; CC_FILES sets the catalog size. */
@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.CodeActionsPart)
@:access(rayde.ui.workbench.DebugPart)
@:access(rayde.ui.workbench.DocumentsPart)
@:access(rayde.ui.workbench.EditorMarksPart)
@:access(rayde.ui.workbench.EditorPart)
@:access(rayde.ui.workbench.ExplorerPart)
@:access(rayde.ui.workbench.ExtensionsPart)
@:access(rayde.ui.workbench.KeymapPart)
@:access(rayde.ui.workbench.LanguagesPart)
@:access(rayde.ui.workbench.MenusPart)
@:access(rayde.ui.workbench.PanelsPart)
@:access(rayde.ui.workbench.ProjectPart)
@:access(rayde.ui.workbench.RunPart)
@:access(rayde.ui.workbench.ShellPart)
@:access(rayde.ui.workbench.TerminalPart)
@:access(rayde.ui.workbench.ThemePart)
class CommandCenterLatencyProbe {
	static function main():Void {
		var count = Std.parseInt(Sys.getEnv("CC_FILES") ?? "429");
		var root = Sys.getCwd() + "bin/center-latency-workspace-" + count;
		sys.FileSystem.createDirectory(root + "/src");
		sys.FileSystem.createDirectory(root + "/empty-extensions");
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/empty-extensions");
		sys.io.File.saveContent(root + "/build.hxml", "-cp src\n-main Main\n");
		var file = root + "/src/Main.hx";
		sys.io.File.saveContent(file, "class Main {\n" + [for(i in 0...2000) ' static var value$i:Int = $i;'].join("\n") + "\n static function main() {}\n}\n");
		for(i in 0...count - 1) sys.io.File.saveContent(root + '/src/Sample$i.hx', 'class Sample$i {}\n');
		ThemeState.init(RestrainedTheme.bundle(), Dark); rayde.ui.Style.use();
		var compiler = new CompilerServer(), tree = new LayoutTree(), stop:Void->Void = null;
		var bench = Owner.root(tree, cleanup -> { stop = cleanup; return new Workbench({display:Display.ofHxml(compiler, root + "/build.hxml"), name:"Panel latency", runtime:"ash"}); });
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
		for(cycle in 0...3) for(open in [true,false]) {
			var before=hl.Gc.stats().totalAllocated, at=haxe.Timer.stamp();
			if(open) bench.openCenter(); else bench.quickOpen.set(false);
			var call=(haxe.Timer.stamp()-at)*1000, frames=[];
			for(_ in 0...10) { frames.push(frame()); Sys.sleep(.005); }
			Sys.println("center-workbench:"+haxe.Json.stringify({cycle:cycle,open:open,call:call,frames:frames,
				allocated:hl.Gc.stats().totalAllocated-before,nodes:tree.order().length})); Sys.stdout().flush();
		}
		stop(); compiler.stop(); tree.dispose(); target.destroy(); texture.destroy();
	}
}
