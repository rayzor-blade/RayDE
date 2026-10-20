import ashui.components.Toast;
import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.theme.ThemeState;
import ashui.theme.themes.RestrainedTheme;

/** Extension notification layout with a wrapping message and an Output action. */
class ToastLayout {
	public static function main():Void {
		for (dark in [true, false]) {
			ThemeState.init(RestrainedTheme.bundle(), dark ? Dark : Light);
			rayde.ui.Style.use();
			var tree = new LayoutTree();
			var root = Owner.root(tree, _ -> <div id="rayde" width={800} height={400}><toaster/></div>);
			function settle() for (_ in 0...40) {
				Offscreen.advance(1/60); Css.setViewport(800, 400); Css.update(); tree.flush(); tree.computeLayout(root.node, 800, 400);
			}
			function bounds(selector:String) return tree.getScrolledBounds(new ashui.layout.Node(Css.query(tree, root.node.id, selector)[0]));
			for (long in [false, true]) {
				var clicked = false;
				Toaster.show({title:"Git", description:long ? "Cannot open this file because it is outside the current repository. Open its project folder and try again." : "File is outside this repository", variant:Destructive, duration:0, action:{label:"Show Output", run:() -> clicked = true}});
				settle();
				var toast = bounds(".ui-toast"), body = bounds(".ui-toast-body"), button = bounds(".ui-button"), label = bounds(".ui-button > text"), close = bounds(".ui-toast-close");
				if (button.height > 28 || label.height > 18 || Math.abs(label.y+label.height/2-button.y-button.height/2) > .5) throw "toast action label has extra line height or is off-center";
				if (body.x+body.width > button.x-8 || button.x+button.width > close.x-8 || close.x+close.width > toast.x+toast.width-12) throw "toast message or actions overlap";
				Snapshot.capture('toast-${dark ? "dark" : "light"}-${long ? "long" : "short"}', tree, root.node, 800, 400, dark ? 0x0d1117 : 0xf5f6fa);
				ashui.input.Pointer.move(tree, button.x+button.width/2, button.y+button.height/2);
				ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); settle();
				if (!clicked || Css.query(tree, root.node.id, ".ui-toast").length != 0) throw "toast action did not run and dismiss the notification";
			}
			tree.dispose();
		}
	}
}
