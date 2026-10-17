import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.theme.ThemeState;
import ashui.theme.themes.RestrainedTheme;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

/**
 * RayDE's workbench on the fixture project, captured in both themes: as it
 * opens, and with a file open and an edit the compiler finds wrong. Pictures
 * go to bin/snapshots, or ASHUI_SNAPSHOT_DIR.
 */
class Snapshots {
	static inline var WIDTH = 1280;
	static inline var HEIGHT = 800;

	static function main():Void {
		var root = Sys.getCwd() + "tests/fixtures/basic", server = new CompilerServer();
		for (dark in [true, false])
			capture(dark, root, server);
		server.stop();
		Sys.println("rayde snapshots: the workbench, empty and with problems, in both themes");
	}

	static function capture(dark:Bool, root:String, server:CompilerServer):Void {
		ThemeState.init(RestrainedTheme.bundle(), dark ? Dark : Light);
		rayde.ui.Style.use();
		var display = Display.ofHxml(server, root + "/build.hxml"), tree = new LayoutTree(), bench:Workbench = null, stop:Void->Void = null;
		var view = Owner.root(tree, s -> {
			stop = s;
			return bench = new Workbench({display: display, name: "basic", runtime: "ash"});
		});
		function settle(frames = 20)
			for (_ in 0...frames) {
				Offscreen.advance(1 / 60);
				Css.setViewport(WIDTH, HEIGHT);
				Css.update();
				tree.flush();
				tree.computeLayout(view.node, WIDTH, HEIGHT);
			}
		function shot(name:String)
			Snapshot.capture('rayde-${dark ? "dark" : "light"}-$name', tree, view.node, WIDTH, HEIGHT, ThemeState.get().color(Background).rgb());
		settle();
		shot("empty");
		var main = root + "/src/Main.hx";
		bench.openFile(main);
		var buffer = bench.buffer(main);
		buffer.set(StringTools.replace(buffer.get(), 'var greeting = "hello";', 'var greeting:Int = "hello";'));
		bench.check(main);
		settle();
		if (bench.problems.get().length != 2)
			throw 'the edited file should show two problems, not ${bench.problems.get().length}';
		shot("problems");
		stop();
		tree.dispose();
	}
}
