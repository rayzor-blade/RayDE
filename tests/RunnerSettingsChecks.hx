import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.ui.RunConfigurationSettings;
import rayde.run.RunConfigurations;

@:access(rayde.ui.RunConfigurationSettings)
class RunnerSettingsChecks {
	public static function main():Void {
		for (dark in [true, false]) {
			var root = Sys.getCwd() + "bin/runner-settings-" + Std.random(0x3fffffff), changes = 0;
			sys.FileSystem.createDirectory(root);
			ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light);
			rayde.ui.Style.use();
			var tree = new LayoutTree(), stop:Void->Void = null;
			var page = Owner.root(tree, cleanup -> {
				stop = cleanup;
				return new RunConfigurationSettings({root: root, onChanged: () -> changes++});
			});
			function flush():Void {
				for (_ in 0...12) {
					ashui.core.render.Offscreen.advance(.025);
					Css.setViewport(1000, 600);
					Css.update();
					tree.flush();
					tree.computeLayout(page.node, 1000, 600);
				}
			}
			flush();
			if (Css.query(tree, page.node.id, "#rayde-run-config-runner").length != 1)
				throw "Run settings did not mount one runner selector";
			page.applyPreset("ashui");
			page.edit(() -> {
				page.configuration.mode = "aot";
				page.configuration.buildFlags = ["--no-fma"];
			});
			var saved = RunConfigurations.load(root, "hl");
			if (saved.runner != "ash" || saved.mode != "aot" || saved.buildFlags[0] != "--no-fma")
				throw "Ash AOT form values were not saved";
			page.pickTarget("js");
			page.applyPreset("tink");
			page.edit(() -> page.configuration.arguments = ["literal $(false)"]);
			saved = RunConfigurations.load(root, "js");
			if (saved.mode != "browser" || saved.framework != "tink" || saved.arguments[0] != "literal $(false)")
				throw "Framework preset did not remain editable";
			page.purpose("preview");
			if (page.configuration.target != "js" || page.configuration.arguments[0] != "literal $(false)")
				throw "Preview did not adopt the browser Run Configuration";
			if (changes != 5)
				throw "Run settings lost change callbacks";
			flush();
			ashui.core.render.Snapshot.capture('runner-settings-${dark ? "dark" : "light"}', tree, page.node, 1000, 600,
				ashui.theme.ThemeState.get().color(Background).rgb());
			stop();
			tree.dispose();
			var rayzor = Owner.root(tree = new LayoutTree(), cleanup -> {
				stop = cleanup;
				return new RunConfigurationSettings({root: root, family: "rayzor"});
			});
			rayzor.pickTarget("aarch64-apple-darwin");
			rayzor.applyPreset("rayzor");
			if (rayzor.configuration.compiler != "rayzor" || rayzor.configuration.mode != "aot")
				throw "Rayzor form used a Haxe backend";
			stop();
			tree.dispose();
		}
		Sys.println("Run settings: target selection, editable framework presets, shared browser profile, Ash AOT, Rayzor triples and callbacks in both themes");
	}
}
