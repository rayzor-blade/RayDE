import ashui.core.render.Offscreen;
import ashui.css.Css;
import ashui.input.Pointer;
import ashui.input.Scroll;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.project.ProjectFile;
import rayde.ui.Workbench;

@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.CodeActionsPart)
@:access(rayde.ui.workbench.DebugPart)
@:access(rayde.ui.workbench.DocumentsPart)
@:access(rayde.ui.workbench.EditorMarksPart)
@:access(rayde.ui.workbench.EditorPart)
@:access(rayde.ui.workbench.ExplorerPart)
@:access(rayde.ui.workbench.ExtensionsPart)
@:access(rayde.ui.workbench.KeymapPart)
@:access(rayde.ui.workbench.LanguagesPart)
@:access(rayde.ui.workbench.MenusPart)
@:access(rayde.ui.workbench.PanelsPart)
@:access(rayde.ui.workbench.ProjectPart)
@:access(rayde.ui.workbench.RunPart)
@:access(rayde.ui.workbench.ShellPart)
@:access(rayde.ui.workbench.TerminalPart)
@:access(rayde.ui.workbench.ThemePart)
class OutputScrollChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	static function main():Void {
		for (dark in [true, false]) run(dark);
		Sys.println("Output scrolling: build and extension follow, wheel pause/resume, selection, resize, hidden updates, channel restoration and cleanup in both themes");
	}
	static function run(dark:Bool):Void {
		var root = Sys.getCwd() + "bin/output-scroll-" + Std.random(0x3fffffff), previous = Sys.getEnv("RAYDE_EXTENSIONS");
		sys.FileSystem.createDirectory(root + "/extensions"); Sys.putEnv("RAYDE_EXTENSIONS", root + "/extensions");
		sys.FileSystem.createDirectory(root + "/extensions/fixture");
		sys.io.File.saveContent(root + "/extensions/fixture/fixture.rayext", '{"name":"Fixture","version":"0.1.0","main":"main.rays","activationEvents":["onCommand:fixture"]}');
		sys.io.File.saveContent(root + "/extensions/fixture/main.rays", "");
		var project = ProjectFile.create(root, "sample", "hxml");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light); rayde.ui.Style.use();
		var tree = new LayoutTree(), compiler = new CompilerServer(), stop:Void->Void = null;
		var bench = Owner.root(tree, cleanup -> { stop = cleanup; return new Workbench({display:Display.ofProject(compiler, project), name:"sample"}); });
		function settle(frames = 8):Void for (_ in 0...frames) {
			Offscreen.advance(.03); Css.setViewport(1100,760); Css.update(); tree.flush(); tree.computeLayout(bench.node,1100,760);
		}
		function viewport():Scroll {
			var ids = Css.query(tree, bench.node.id, ".rayde-output .ui-code-viewport");
			check(ids.length == 1, "Output viewport is missing or duplicated");
			return Scroll.at(ids[0], tree);
		}
		function atEnd(message:String):Void {
			var scroll = viewport();
			check(scroll.limits().y > 0 && Math.abs(scroll.limits().y - scroll.y.get()) < 1, message + ': ' + scroll.y.get() + '/' + scroll.limits().y);
		}
		function publish(channel:String, count:Int):Void {
			var lines = [for (i in 0...count) 'Output line $i'], text = lines.join("\n");
			if (channel == "build") bench.runPart.publishBuildOutput(text);
			else {
				var entry = bench.extensionsPart.extensionManager.find("fixture");
				check(entry != null, "Fixture extension was not discovered");
				entry.output.resize(0); entry.outputKinds.resize(0); entry.log(text);
				bench.extensionsPart.refreshExtensionOutput();
			}
			var end = haxe.Timer.stamp() + 5;
			while (bench.extensionsPart.outputState(channel).value.get() != text && haxe.Timer.stamp() < end) {
				bench.extensionsPart.pollOutput(); settle(1); Sys.sleep(.005);
			}
			check(bench.extensionsPart.outputState(channel).value.get() == text, "Output worker did not deliver " + channel); settle();
		}
		try {
			settle(); bench.panelsPart.showPanel("console"); settle();
			for (channel in ["build", "ext:fixture"]) {
				bench.extensionsPart.outputChannel.set(channel); settle();
				publish(channel,120); atEnd(channel + " did not follow its first long log");
				var state = bench.extensionsPart.outputState(channel);
				state.applyRemote(state.value.get(), {caret:6,anchor:2}); settle();
				publish(channel,150); atEnd(channel + " did not follow appended output");
				var scroll = viewport(), bounds = tree.getScrolledBounds(scroll.node);
				Pointer.move(tree,bounds.x + 80,bounds.y + bounds.height / 2); Pointer.wheel(tree,0,120); settle();
				var paused = scroll.y.get();
				check(paused < scroll.limits().y - 1, "Wheel did not scroll Output up");
				publish(channel,180);
				check(Math.abs(scroll.y.get() - paused) < 1, "New output moved a reader away from earlier lines");
				bench.panelsPart.closePanel(); settle();
				check(!state.mounted && Css.query(tree,bench.node.id,".rayde-output").length == 0, "Hidden Output retained its view");
				check(state.caret == 6 && state.anchor == 2, "Following Output changed the selected text");
				publish(channel,210); bench.panelsPart.showPanel("console"); settle(); scroll = viewport();
				check(Math.abs(scroll.y.get() - paused) < 1, "Reopening paused Output jumped to the latest line: " + channel + " " + paused + " -> " + scroll.y.get() + "/" + scroll.limits().y + " saved=" + state.scrollY);
				Pointer.move(tree, bounds.x + 80,bounds.y + bounds.height / 2); Pointer.wheel(tree,0,-100000); settle();
				publish(channel,240); atEnd(channel + " did not resume following after scrolling to the end");
				bench.panelsPart.setPanelHeight(320); settle(); atEnd("Resizing Output lost the latest line");
				bench.panelsPart.closePanel(); settle();
				var hooks = LayoutTree.layoutHooks.length;
				publish(channel,270); bench.panelsPart.showPanel("console"); settle(); atEnd("Hidden output did not catch up when reopened");
				for (_ in 0...3) { bench.panelsPart.closePanel(); settle(); bench.panelsPart.showPanel("console"); settle(); }
				bench.panelsPart.closePanel(); settle();
				check(LayoutTree.layoutHooks.length == hooks, "Output retained layout hooks after hiding");
				bench.panelsPart.showPanel("console"); settle();
				publish(channel,1); check(viewport().y.get() == 0, "Clearing Output left an invalid scroll offset");
				publish(channel,300); atEnd("Output stopped following after a shorter replacement");
				viewport().scrollTo(0,120); settle();
			}
			bench.extensionsPart.outputChannel.set("build"); settle();
			check(Math.abs(viewport().y.get() - 120) < 1, "Switching Output channels lost the paused position");
			bench.extensionsPart.outputChannel.set("ext:fixture"); settle();
			check(Math.abs(viewport().y.get() - 120) < 1, "Extension Output lost its independent position");
		} catch (error:Dynamic) { stop(); tree.dispose(); compiler.stop(); Sys.putEnv("RAYDE_EXTENSIONS", previous ?? ""); throw error; }
		stop(); tree.dispose(); compiler.stop(); Sys.putEnv("RAYDE_EXTENSIONS", previous ?? "");
	}
}
