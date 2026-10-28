import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

@:access(rayde.ui.Workbench)
class ActivityBarChecks {
	static function main():Void {
		var root = Sys.getCwd() + "bin/activity-layout-" + Std.random(0x3fffffff);
		sys.FileSystem.createDirectory(root + "/.rayde");
		var server = new CompilerServer();
		for (theme in ["restrained", "hybrid", "expressive"]) {
			sys.io.File.saveContent(root + "/.rayde/settings.json", haxe.Json.stringify({appearance: {theme: theme, scheme: "dark"}}));
			ashui.theme.ThemeState.init(rayde.ui.Theming.bundle(theme), Dark);
			rayde.ui.Style.use();
			var tree = new LayoutTree(), dispose = () -> {};
			var bench = Owner.root(tree, stop -> {
				dispose = stop;
				return new Workbench({display: new Display(server, root, []), name: "Activity", empty: true});
			});
			try {
				for (shown in [false, true]) {
					bench.treeWidth.set(shown ? 308 : 48);
					for (_ in 0...8) {
						ashui.core.render.Offscreen.advance(1 / 60);
						Css.setViewport(1280, 800);
						Css.update();
						tree.flush();
						tree.computeLayout(bench.node, 1280, 800);
					}
					var rails = Css.query(tree, bench.node.id, "#rayde-activity");
					if (rails.length != 1)
						throw "Activity rail missing";
					var rail = tree.getScrolledBounds(new Node(rails[0]));
					var items = Css.query(tree, bench.node.id, ".rayde-activity-item");
					if (items.length < 2)
						throw "Expected top and bottom activity items";
					for (id in items) {
						var box = tree.getScrolledBounds(new Node(id));
						if (Math.abs(box.x + box.width / 2 - rail.x - rail.width / 2) > .5)
							throw 'Activity item is off center in $theme (expanded=$shown): $box / $rail';
					}
				}
			} catch (error:Dynamic) {
				dispose();
				tree.dispose();
				server.stop();
				throw error;
			}
			dispose();
			tree.dispose();
		}
		server.stop();
		Sys.println("Activity bar: top and bottom items stay centered with the sidebar collapsed and expanded in every built-in theme");
	}
}
