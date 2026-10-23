import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.ext.Manifest;
import rayde.ext.Studio;

class NativeExtensionViewChecks {
	static function main():Void {
		var manifest = Manifest.read(Sys.getCwd() + "bin/check-native-isolation/native-test.rayext");
		var tree = new LayoutTree(), studio:Studio = null, stop:Void->Void = null, tabs = -1;
		var source = 'native "fixture" { function native_abort():Void; } '
			+ 'registerCommand("crash", () -> native_abort()); '
			+ 'mount(() -> <div>Sidebar</div>, "main"); mount(() -> <div>Tab</div>, "tab:Native view");';
		Owner.root(tree, cleanup -> {
			stop = cleanup;
			var root = <div/>;
			studio = new Studio(manifest.mainPath(),() -> source,tree,manifest);
			studio.connection.nativeAllowed = _ -> true;
			studio.onTabs = list -> tabs = list.length;
			studio.attach(root.node); studio.reload();
			return root;
		});
		function wait(done:Void->Bool):Void {
			var end = haxe.Timer.stamp() + 8;
			while (!done() && haxe.Timer.stamp() < end) { studio.tick(); tree.flush(); Sys.sleep(.005); }
			if (!done()) throw "Isolated extension presentation did not settle: " + studio.connection.state;
		}
		wait(() -> studio.preview.count() > 0 && tabs == 1);
		studio.connection.command("crash",null);
		wait(() -> studio.connection.state == "exited");
		if (studio.preview.count() != 0 || studio.preview.roots.length != 0 || studio.tabViews.length != 0 || tabs != 0)
			throw "Native host crash retained its view model or editor tabs";
		studio.dispose(); stop(); tree.dispose();
		Sys.println("Native extension presentations: crash released its node model, roots and tabs");
	}
}
