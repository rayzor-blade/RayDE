import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;
import rayde.workspace.Fs;
import rayde.workspace.Procs;

@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.ExplorerPart)
class BuildOpeningChecks {
	static function check(ok:Bool,message:String):Void if (!ok) throw message;
	static function main():Void {
		var disk = new HeldBuildWorkspace(), previous = Fs.current, launcher = Procs.current, home = Sys.getEnv("HOME"), extensions = Sys.getEnv("RAYDE_EXTENSIONS");
		disk.createDirectory("/work/src"); disk.createDirectory("/home/test"); disk.createDirectory("/empty-extensions");
		disk.saveContent("/work/src/Main.hx","class Main {}\n"); disk.saveContent("/work/build.hxml","-cp src\n-main Main\n--interp\n");
		Fs.current = disk; Procs.current = new rayde.workspace.NoLauncher(); Sys.putEnv("HOME","/home/test"); Sys.putEnv("RAYDE_EXTENSIONS","/empty-extensions");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),Light); rayde.ui.Style.use();
		var tree = new LayoutTree(), compiler = new CompilerServer(), stop:Void->Void = null;
		var bench = Owner.root(tree,cleanup -> { stop = cleanup; return new Workbench({display:new Display(compiler,"/work",["-cp","src"],"/work/build.hxml"),name:"sample"}); });
		function settle():Void for (_ in 0...4) { Css.setViewport(1100,800); Css.update(); tree.flush(); tree.computeLayout(bench.node,1100,800); }
		function nodes(selector:String) return Css.query(tree,bench.node.id,selector);
		function until(done:Void->Bool):Void {
			var end = haxe.Timer.stamp()+5;
			while (!done() && haxe.Timer.stamp()<end) { settle(); Sys.sleep(.005); }
			check(done(),"Build settings did not settle"); settle();
		}
		try {
			bench.openProject(); settle(); disk.held = true;
			bench.explorerPart.openExplorerFile("/work/build.hxml"); settle(); disk.entered.await();
			check(bench.active.get() == Workbench.SETTINGS && nodes("#rayde-build-loading").length == 1,"Explorer must open Settings before the build file arrives");
			check(!disk.onUi,"Opening build settings touched the provider on the UI thread");
			bench.openSettings("terminal"); settle();
			check(nodes("#rayde-terminal-settings").length == 1,"A pending build read blocked Settings navigation");
			bench.closeAll(); settle(); disk.release.resolve(true);
			until(() -> !bench.buildLoad.state.get().loading);
			check(bench.buildFile() == null && nodes("#rayde-settings").length == 0,"Closing Settings retained or remounted the pending build");
			disk.held = false; disk.fail = true;
			bench.openBuild(); until(() -> nodes("#rayde-build-load-error").length == 1);
			check(nodes("#rayde-build-main").length == 0 && nodes("#rayde-build-retry").length == 1,"Failed reads must offer Retry without editing an empty build");
			disk.fail = false; bench.buildLoad.load("/work/build.hxml");
			until(() -> nodes("#rayde-build-main").length == 1);
			check(bench.buildFile().value("--main") == "Main","Retry did not load the real build");
			Sys.println("Build opening: worker-only reads, immediate loading, navigation, close cancellation, error and retry passed");
		} catch (error:Dynamic) { disk.release.resolve(true); disk.held=false; stop(); tree.dispose(); Fs.current=previous; Procs.current=launcher; Sys.putEnv("HOME",home); Sys.putEnv("RAYDE_EXTENSIONS",extensions); throw error; }
		stop(); tree.dispose(); compiler.stop(); Fs.current=previous; Procs.current=launcher; Sys.putEnv("HOME",home); Sys.putEnv("RAYDE_EXTENSIONS",extensions);
	}
}

private class HeldBuildWorkspace extends rayde.workspace.MemoryWorkspace {
	final owner = sys.thread.Thread.current();
	public final entered = new ash.Future<Bool>();
	public final release = new ash.Future<Bool>();
	public var held = false;
	public var fail = false;
	public var onUi = false;
	public function new() super();
	function query(path:String):Void {
		if (path != "/work/build.hxml" || !held && !fail) return;
		if (sys.thread.Thread.current() == owner) { onUi = true; throw "Build filesystem call on UI"; }
		if (fail) throw "Read unavailable";
		if (!entered.isReady()) entered.resolve(true); release.await();
	}
	override public function exists(path:String):Bool { query(path); return super.exists(path); }
	override public function isDirectory(path:String):Bool { query(path); return super.isDirectory(path); }
	override public function getContent(path:String):String { query(path); return super.getContent(path); }
}
