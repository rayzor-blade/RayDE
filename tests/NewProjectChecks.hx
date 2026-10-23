import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.css.Identity;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import rayde.ui.NewProject;

@:access(rayde.ui.NewProject)
class NewProjectChecks {
	static function check(value:Bool, message:String):Void { if (!value) throw message; }
	static function main():Void {
		for (dark in [true, false]) for (size in [{w:1280, h:800}, {w:680, h:680}, {w:960, h:540}]) run(dark, size.w, size.h);
		Sys.println("new project: template grid, filtering, keyboard selection, bounds, scrolling, validation, worker creation, retry and owner cleanup in both themes");
	}

	static function run(dark:Bool, width:Int, height:Int):Void {
		var scratch = Sys.getCwd() + "bin/new-project-" + Std.random(0x3fffffff);
		sys.FileSystem.createDirectory(scratch);
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light); rayde.ui.Style.use();
		var tree = new LayoutTree(), stop:Void->Void = null, form:NewProject = null;
		var opened = Signal.make(false), created = "";
		var templates = Signal.make(rayde.project.ProjectTemplates.all.copy());
		var disposedImages = 0, observeImage = (_:ashui.types.Bitmap) -> disposedImages++;
		ashui.types.Bitmap.disposing.push(observeImage);
		function mount():ashui.layout.Element { form = new NewProject({opened:opened, directory:scratch, templates:() -> templates.get(), onCreate:path -> created = path}); return form; }
		var root = Owner.root(tree, cleanup -> {
			stop = cleanup;
			return <div id="rayde" widthPercent={1} heightPercent={1} class="bg-background text-text-primary"><text>RayDE workspace</text><if {opened.get()}>${mount()}</if></div>;
		});
		function settle(frames=16):Void for (_ in 0...frames) {
			Offscreen.advance(1/60); Css.setViewport(width, height); Css.update(); tree.flush(); tree.computeLayout(root.node, width, height);
		}
		function nodes(selector:String) return Css.query(tree, root.node.id, selector);
		function bounds(selector:String) {
			var ids = nodes(selector); check(ids.length == 1, "Missing or duplicate " + selector);
			return tree.getScrolledBounds(new ashui.layout.Node(ids[0]));
		}
		function click(selector:String):Void {
			var b = bounds(selector);
			ashui.input.Pointer.move(tree, b.x + b.width / 2, b.y + b.height / 2);
			ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); settle();
		}
		function press(key:window.Key):Void {
			for (state in [window.MouseElementState.Pressed, window.MouseElementState.Released])
				ashui.input.Keyboard.input(tree, window.KeyEvent.Input(Unidentified(Unidentified), key, None, Standard, state, false, Unavailable));
			settle();
		}
		function count():Int return [for (_ in (@:privateAccess Identity.trees.get(tree))) 1].length;
		function texts():Int return [for (_ in (@:privateAccess ashui.ui.Text.byNode)) 1].length;
		function until(done:Void->Bool):Void {
			var deadline = haxe.Timer.stamp() + 5;
			while (!done() && haxe.Timer.stamp() < deadline) { settle(2); Sys.sleep(.005); }
			check(done(), "Project worker did not complete"); settle();
		}
		function shot(name:String):Void Snapshot.capture('new-project-${dark ? "dark" : "light"}-$width-$height-$name', tree, root.node, width, height, ashui.theme.ThemeState.get().color(Background).rgb());
		try {
			settle(); var base = count(), baseTexts = texts(), hooks = ashui.input.Pointer.hooks.length;
			check(nodes(".rayde-project-template").length == 0, "Closed modal built template cards");
			opened.set(true); settle(); shot("all");
			check(nodes(".rayde-project-template").length == rayde.project.ProjectTemplates.all.length, "Missing ecosystem templates");
			var custom:rayde.project.ProjectTemplates.ProjectTemplate = {id:"ext:fixture:console", owner:"fixture", icon:"terminal", name:"Custom Console", category:"Applications", description:"Extension starter", target:"Cross-platform", requirements:"Haxe", command:"haxe build.hxml", docs:"", scaffold:{entry:"build.hxml", files:["build.hxml" => "-cp src\n-main Main\n"]}};
			templates.set(rayde.project.ProjectTemplates.all.concat([custom])); settle();
			ashui.input.Scroll.at(nodes("#rayde-project-catalog")[0], tree).scrollTo(0, 1e9); settle();
			click("#" + NewProject.templateId(custom.id));
			check(form.selected.get() == custom.id, "Extension starter did not appear in the live catalog");
			check(ashui.ui.Text.at(nodes("#rayde-project-requirements")[0]).text() == custom.requirements, "Selected starter did not update its requirements");
			templates.set(rayde.project.ProjectTemplates.all.copy()); settle();
			ashui.input.Scroll.at(nodes("#rayde-project-catalog")[0], tree).scrollTo(0, 0); settle();
			check(form.selected.get() == "hxml" && nodes("#" + NewProject.templateId(custom.id)).length == 0, "Removed extension starter retained its card or selection");
			var panel = bounds("#rayde-project-modal"), footer = bounds("#rayde-project-footer");
			check(panel.x >= -1 && panel.y >= -1 && panel.x + panel.width <= width + 1 && panel.y + panel.height <= height + 1, "Project modal exceeds the window");
			check(footer.y + footer.height <= panel.y + panel.height && bounds("#rayde-project-name").height >= 30, "Project controls are clipped");
			var first = bounds("#rayde-project-template-hxml"), second = bounds("#rayde-project-template-ash"), third = bounds("#rayde-project-template-ashui");
			check(first.width > 150 && second.x > first.x && (width > 720 ? third.x > second.x : third.y > first.y), "Template cards are not a responsive grid");
			var grid = bounds(".rayde-project-grid"), end = width > 720 ? third : second;
			check(end.x + end.width >= grid.x + grid.width - 4, "Template grid leaves unused space at the right");
			var catalog = bounds("#rayde-project-catalog"), scroll = ashui.input.Scroll.at(nodes("#rayde-project-catalog")[0], tree);
			if (scroll != null && scroll.limits().y > 0) {
				ashui.input.Pointer.move(tree, catalog.x + catalog.width / 2, catalog.y + catalog.height / 2); ashui.input.Pointer.wheel(tree, 0, -10000); settle();
				var last = bounds("#rayde-project-template-lime");
				check(scroll.y.get() > 0 && last.y + last.height <= catalog.y + catalog.height + 1 && bounds("#rayde-project-footer").y == footer.y, "Scrolling templates moved the form or hid the final card");
				shot("scrolled"); scroll.y.set(0); settle();
			}
			click("#rayde-project-category-games");
			check(nodes(".rayde-project-template").length == rayde.project.ProjectTemplates.matching("Games").length && form.selected.get() == "heaps", "Category filter lost its visible selection");
			var flixel = nodes("#rayde-project-template-flixel")[0];
			ashui.input.Focus.set(ashui.input.Interaction.byId(tree, flixel), true); press(window.Key.Named(Enter));
			check(form.selected.get() == "flixel" && nodes("#rayde-project-template-flixel[data-selected]").length == 1, "Keyboard activation did not select a template");
			shot("games");
			form.name.set("../invalid"); click("#rayde-project-create");
			check(opened.get() && nodes("#rayde-project-error").length == 1 && !form.busy.get(), "Invalid name escaped the modal");
			form.name.set("existing"); sys.FileSystem.createDirectory(scratch + "/existing");
			click("#rayde-project-create"); until(() -> !form.busy.get());
			check(opened.get() && form.error.get() != "" && created == "", "Creation failure discarded the form");
			form.name.set("my-game"); click("#rayde-project-create"); until(() -> created != "");
			check(!opened.get() && StringTools.endsWith(created, "/my-game/haxelib.json") && sys.FileSystem.exists(scratch + "/my-game/src/PlayState.hx"), "Selected template did not create and open its project");
			form = null; settle();
			check(count() == base && texts() == baseTexts && nodes("#rayde-project-modal").length == 0 && ashui.input.Pointer.hooks.length == hooks, "Closed project modal retained UI, text or pointer hooks");
			check(disposedImages >= 3, "Original raster logos retained their decoded pixels after cards unmounted");
			for (_ in 0...3) { opened.set(true); settle(); press(window.Key.Named(Escape)); form = null; settle(); check(!opened.get() && count() == base, "Escape or repeated opens retained the catalog"); }
		} catch (error:Dynamic) { stop(); tree.dispose(); ashui.types.Bitmap.disposing.remove(observeImage); throw error; }
		stop(); tree.dispose(); ashui.types.Bitmap.disposing.remove(observeImage);
	}
}
