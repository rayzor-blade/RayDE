import ashui.css.Css;
import ashui.css.Identity;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import rayde.ui.ExplorerTree;
import rayde.ui.Icons;

/** Ignored filenames stay distinct without becoming illegible on a light surface or selection. */
class ExplorerContrastChecks {
	static function check(ok:Bool, why:String):Void {
		if (!ok)
			throw why;
	}

	static function main():Void {
		for (dark in [false, true]) {
			ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light);
			rayde.ui.Style.use();
			var tree = new LayoutTree(),
				stop:Void->Void = null,
				selected = Signal.make("/workspace/ordinary.hx");
			var root = Owner.root(tree, cleanup -> {
				stop = cleanup;
				return <div id="rayde" width={320} height={220}>
					<text id="primary" class="text-text-primary">Primary</text><text id="secondary" class="text-text-secondary">Secondary</text>
					<explorer-tree root="/workspace" name="Workspace" head={() -> null} icon={_ -> Icons.FILE_CODE_LINE} ignored={path -> path == "/workspace/ignored.txt"}
						opened={_ -> true} state={(_,initial) -> Signal.make(initial)} selected={selected} onSelect={selected.set} onPress={_ -> {}} revision={() -> 0}
						entries={_ -> [{name:"ordinary.hx",path:"/workspace/ordinary.hx",directory:false},{name:"ignored.txt",path:"/workspace/ignored.txt",directory:false}]}/>
				</div>;
			});
			function settle():Void
				for (_ in 0...8) {
					Css.update();
					tree.flush();
					tree.computeLayout(root.node, 320, 220);
				}
			function value(selector:String, property:String):Null<String> {
				var found = Css.query(tree, root.node.id, selector);
				check(found.length == 1, "Missing contrast target " + selector);
				return Css.resolved(Identity.of(tree, found[0]), property);
			}
			settle();
			var ordinary = '.ui-tree-item[data-path="/workspace/ordinary.hx"] > .ui-tree-row',
				ignored = '.ui-tree-item[data-path="/workspace/ignored.txt"] > .ui-tree-row';
			check(value(ordinary, "color") == value("#primary", "color"), "Selected ordinary filename lost primary contrast");
			if (!dark) {
				check(value(ignored, "color") == value("#secondary", "color"), "Ignored light filename lost readable secondary color");
				check(value(ignored + " > .ui-tree-label", "opacity") == "1", "Ignored light filename still had stacked opacity");
			}
			selected.set("/workspace/ignored.txt");
			settle();
			if (!dark)
				check(value(ignored, "color") == value("#primary", "color"), "Selected ignored filename stayed washed out");
			stop();
			tree.dispose();
		}
		Sys.println("Explorer contrast: ordinary, ignored and selected filenames checked in light and dark schemes");
	}
}
