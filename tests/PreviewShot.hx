import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.theme.ThemeState;
import ashui.theme.themes.RestrainedTheme;
import rayde.ext.Studio;

/**
 * An extension run through the Studio and drawn by the Preview, captured in both themes: what its markup
 * and classes look like, and that a click in the Preview reaches the extension and the change comes back.
 */
class PreviewShot {
	static inline var WIDTH = 520;
	static inline var HEIGHT = 420;

	static var failures:Array<String> = [];

	static final SCRIPT = "var n = signal(0);
var items = signal(['Alpha', 'Beta', 'Gamma']);
mount(() -> <div class='flex flex-col gap-3 p-4'>
  <h1 class='text-2xl font-semibold'>Word count</h1>
  <p class='text-text-secondary text-sm'>A panel an extension drew.</p>
  <div class='flex items-center gap-2'>
    <button class='px-3 py-1 rounded-md bg-primary text-text-inverse' onClick={() -> n.value++}>Add</button>
    <span>Clicked {n} times</span>
  </div>
  <ul class='flex flex-col gap-1'><for {x in items}><li class='px-2 py-1 rounded bg-surface-elevated'>{x}</li></for></ul>
  <div style='height: 6px; background: var(--accent); width: 40%'></div>
</div>, 'panel');";

	static function check(ok:Bool, what:String):Void
		if (!ok)
			failures.push(what);

	static function main():Void {
		for (dark in [true, false])
			scenario(dark);
		if (failures.length > 0) {
			Sys.println("preview checks failed:\n  " + failures.join("\n  "));
			Sys.exit(1);
		}
		Sys.println("preview checks: an extension's view drawn, and a click reaching it, passed");
	}

	static function scenario(dark:Bool):Void {
		ThemeState.init(RestrainedTheme.bundle(), dark ? Dark : Light);
		rayde.ui.Style.use();
		var dir = Sys.getCwd() + "bin/preview-shot", file = dir + "/main.rays";
		sys.FileSystem.createDirectory(dir);
		sys.io.File.saveContent(file, SCRIPT);
		var tree = new LayoutTree(), studio:Studio = null;
		var view = Owner.root(tree, s -> new ashui.ui.Div({classes: ["flex", "flex-col"]}));
		function settle(?frames:Int):Void
			for (_ in 0...(frames == null ? 6 : frames)) {
				Offscreen.advance(1 / 60);
				ashui.css.Css.setViewport(WIDTH, HEIGHT);
				Css.update();
				tree.flush();
				tree.computeLayout(view.node, WIDTH, HEIGHT);
			}
		function until(done:Void->Bool, what:String):Void {
			var end = haxe.Timer.stamp() + 10;
			while (!done() && haxe.Timer.stamp() < end) {
				studio.tick();
				settle(2);
				Sys.sleep(.01);
			}
			check(done(), 'timed out waiting for $what');
		}
		studio = new Studio(file, dir + "/host", () -> sys.io.File.getContent(file), tree);
		if (studio.state.get() == "unavailable") {
			Sys.println("preview checks skipped: no rayscript-host");
			return;
		}
		studio.attach(view.node);
		studio.reload();
		until(() -> studio.preview.count() > 12, "the view");
		settle();
		check(studio.console.get().length == 0, 'the console should be empty: ${studio.console.get().map(e -> e.text)}');
		Snapshot.capture('preview-${dark ? "dark" : "light"}-view', tree, view.node, WIDTH, HEIGHT, ThemeState.get().color(Background).rgb());
		var outline = studio.preview.outline();
		check(Lambda.exists(outline, o -> o.tag == "button" && o.listens.indexOf("click") >= 0), "the button listens for clicks");
		// A press and release on the button, as the pointer makes them.
		var button = Css.query(tree, view.node.id, "[data-tag=button], button");
		check(button.length > 0, "the button is in the tree");
		if (button.length > 0) {
			var at = tree.getScrolledBounds(new ashui.layout.Node(button[0]));
			ashui.input.Pointer.move(tree, at.x + at.width / 2, at.y + at.height / 2);
			ashui.input.Pointer.press(tree);
			ashui.input.Pointer.release(tree);
			settle(3);
			until(() -> Lambda.exists(studio.preview.outline(), o -> o.text == "1"), "the click to come back as text");
			settle();
			Snapshot.capture('preview-${dark ? "dark" : "light"}-clicked', tree, view.node, WIDTH, HEIGHT, ThemeState.get().color(Background).rgb());
		}
		studio.dispose();
	}
}
