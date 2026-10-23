import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.ui.RunnerSettings;
import rayde.project.ProjectRunner;

@:access(rayde.ui.RunnerSettings)
class RunnerSettingsChecks {
	public static function main():Void {
		for (dark in [true, false]) {
			var root = Sys.getCwd() + "bin/runner-settings-" + Std.random(0x3fffffff), changes = 0;
			sys.FileSystem.createDirectory(root);
			ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light); rayde.ui.Style.use();
			var tree = new LayoutTree(), stop:Void->Void = null;
			var page = Owner.root(tree, cleanup -> { stop = cleanup; return new RunnerSettings({root:root, onChanged:() -> changes++}); });
			for (_ in 0...12) { ashui.core.render.Offscreen.advance(.025); Css.setViewport(1000,600); Css.update(); tree.flush(); tree.computeLayout(page.node,1000,600); }
			if (Css.query(tree, page.node.id, "#rayde-runner-default").length != 1) throw "Run settings did not mount the runner selector";
			page.save("hashlink"); if (ProjectRunner.resolve(root) != "hashlink") throw "Settings did not persist the HashLink override";
			page.save("ash"); if (ProjectRunner.resolve(root) != "ash") throw "Settings did not persist the Ash override";
			page.save("auto"); if (changes != 3 || ProjectRunner.resolve(root) != ProjectRunner.defaultHashlink()) throw "Settings lost the automatic platform default or callback";
			for (_ in 0...12) { ashui.core.render.Offscreen.advance(.025); Css.update(); tree.flush(); tree.computeLayout(page.node,1000,600); }
			ashui.core.render.Snapshot.capture('runner-settings-${dark ? "dark" : "light"}',tree,page.node,1000,600,ashui.theme.ThemeState.get().color(Background).rgb());
			stop(); tree.dispose();
		}
		Sys.println("runner settings: visible selector, persisted overrides, automatic platform default and callbacks in both themes");
	}
}
