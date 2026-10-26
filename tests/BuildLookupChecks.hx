import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.build.HxmlFile;
import rayde.ui.BuildSettings;
import rayde.workspace.Fs;

class BuildLookupChecks {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;
	static function main():Void {
		var previous = Fs.current, disk = new GatedWorkspace();
		disk.createDirectory("/work/src"); disk.createDirectory("/work/examples");
		disk.createDirectory("/work/node_modules/huge"); disk.saveContent("/work/src/Main.hx","class Main {}");
		disk.saveContent("/work/examples/Example.hx","class Example {}");
		disk.active = true;
		Fs.current = disk;
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),Light); rayde.ui.Style.use();
		var tree = new LayoutTree(), stop:Void->Void = null;
		var root = Owner.root(tree, cleanup -> { stop = cleanup; return new BuildSettings({root:"/work",file:new HxmlFile("/work/build.hxml","-cp src\n-main Main\n-hl bin/app.hl\n"),onChanged:() -> {}}); });
		function settle():Void for (_ in 0...3) { Css.update(); tree.flush(); tree.computeLayout(root.node,1000,800); }
		try {
			settle(); disk.entered.await();
			check(Css.query(tree,root.node.id,"#rayde-build-main").length == 1,"build form must render while filesystem lookups are blocked");
			check(!disk.onUi,"rendering must not query the filesystem");
			disk.release.resolve(true);
			var until = haxe.Timer.stamp()+4;
			while (Css.query(tree,root.node.id,"#rayde-build-main-found").length == 0 && haxe.Timer.stamp()<until) { Sys.sleep(.005); settle(); }
			check(Css.query(tree,root.node.id,"#rayde-build-main-found").length == 1,"background class lookup must update the form");
			check(!disk.generated,"suggestions must not descend into generated dependencies");
			Sys.println("build form: immediate controls, worker-only filesystem checks and generated-directory exclusion passed");
		} catch (error:Dynamic) { disk.release.resolve(true); stop(); Fs.current=previous; throw error; }
		stop(); Fs.current=previous;
	}
}

private class GatedWorkspace extends rayde.workspace.MemoryWorkspace {
	final owner = sys.thread.Thread.current();
	public final entered = new ash.Future<Bool>();
	public final release = new ash.Future<Bool>();
	public var onUi = false;
	public var generated = false;
	public var active = false;
	public function new() super();
	function query(path:String):Void {
		if (!active) return;
		if (sys.thread.Thread.current() == owner) { onUi = true; throw "Filesystem call on UI"; }
		if (path.indexOf("node_modules/") >= 0) generated = true;
		if (!entered.isReady()) entered.resolve(true); release.await();
	}
	override public function exists(path:String):Bool { query(path); return super.exists(path); }
	override public function isDirectory(path:String):Bool { query(path); return super.isDirectory(path); }
	override public function readDirectory(path:String):Array<String> { query(path); return super.readDirectory(path); }
}
