import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.project.CaribouProject;
import rayde.project.ProjectFile;
import rayde.run.CaribouDiagnostics;
import rayde.run.Runner;


/** A Caribou project is opened through `caribou project --json`, run and built through `caribou`, and its findings land in Problems; a fake `caribou` stands in for the real one. */
@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.ExplorerPart)
class CaribouProjectChecks {
	static function check(value:Bool, message:String):Void { if (!value) throw message; }
	static function main():Void {
		run();
		workbench();
		real();
	}

	/** Against the real `caribou`, when there is one and its example is there: its answer must be one this reader takes. */
	static function real():Void {
		Sys.putEnv("CARIBOU", "");
		var caribou = CaribouProject.binary(), example = Sys.getCwd() + "../caribou/examples/browser-interop/flock.cbproj";
		if (caribou == null || !sys.FileSystem.exists(example)) { Sys.println("Caribou real: skipped, no caribou with its examples beside RayDE"); return; }
		var probe = new sys.io.Process(caribou, ["project", "--json", example]), out = probe.stdout.readAll().toString(); probe.exitCode(); probe.close();
		if (out == "") { Sys.println("Caribou real: skipped, this caribou has no `project --json`"); return; }
		var project = ProjectFile.read(example);
		check(project.kind == "caribou" && project.name == "flock" && project.args[0] == "--cwd" && project.args.indexOf("-cp") > 0 && project.args[project.args.indexOf("-cp") + 1] == "src", 'the real project: ${project.args}');
		check(project.args.indexOf("-main") > 0 && project.args.indexOf("-hl") > 0, "the real arguments carry -main and -hl");
		// A program that does not compile: Caribou's own finding arrives at the line, through the runner.
		var scratch = Sys.getCwd() + "bin/caribou-real-" + Std.random(0x3fffffff);
		sys.FileSystem.createDirectory(scratch); sys.FileSystem.createDirectory(scratch + "/src");
		sys.io.File.saveContent(scratch + "/scratch.cbproj", '[project]\nname = "scratch"\nentry = "haxe:Main"\nlanguages = ["haxe"]\n');
		sys.io.File.saveContent(scratch + "/src/Main.hx", 'class Main {\n  static function main() {\n    var x:Int = "oops";\n    trace(x);\n  }\n}\n');
		var runner = new Runner(Display.ofProject(new CompilerServer(), scratch + "/scratch.cbproj"));
		runner.start();
		var end = haxe.Timer.stamp() + 120;
		while (runner.active() && haxe.Timer.stamp() < end) { runner.tick(); Sys.sleep(.05); }
		runner.tick();
		var found = [for (p in runner.problems) if (p.message == "String should be Int") p];
		if (found.length == 0 && runner.console.indexOf("--diagnostics") >= 0) { Sys.println("Caribou real: skipped the run, this caribou has no --diagnostics"); return; }
		check(runner.state == "finished" && runner.exitCode != 0, 'a program that does not compile ends with a failure: ${runner.state} ${runner.exitCode}');
		check(found.length == 1 && found[0].file == sys.FileSystem.fullPath(scratch) + "/src/Main.hx" && found[0].range.start.line == 2 && found[0].range.start.character == 4 && found[0].severity == 1, 'the error is at its line: ${runner.problems}\n${runner.console}');
		Sys.println("Caribou real: the project in the caribou repository opens as caribou describes it, and a compile error arrives at its line");
	}

	/** A Caribou project in the workbench: its file's problems are workspace problems, and the file is in the Explorer. */
	static function workbench():Void {
		var root = Sys.getCwd() + "bin/caribou-ui-" + Std.random(0x3fffffff);
		for (d in [root, root + "/game/src", root + "/empty-extensions"]) sys.FileSystem.createDirectory(d);
		var project = root + "/game";
		sys.io.File.saveContent(project + "/game.cbproj", '[project]\nname = "game"\n');
		sys.io.File.saveContent(root + "/project.json", '{"dir":"$project","name":"game","entry":{"language":"haxe","module":"game.Main"},"languages":["haxe"],"haxe":{"cwd":"$project","args":["-cp","src"]},"problems":[{"key":"plugins.window","message":"library not built yet"}]}');
		sys.io.File.saveContent(root + "/caribou", "#!/bin/sh\ncat \"" + root + "/project.json\"\n");
		Sys.command("chmod", ["+x", root + "/caribou"]);
		Sys.putEnv("CARIBOU", root + "/caribou"); Sys.putEnv("RAYDE_EXTENSIONS", root + "/empty-extensions");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), Dark); rayde.ui.Style.use();
		var display = Display.ofProject(new CompilerServer(), project + "/game.cbproj"), tree = new ashui.layout.LayoutTree(), stop:Void->Void = null;
		var bench = ashui.reactive.Owner.root(tree, cleanup -> { stop = cleanup; return new rayde.ui.Workbench({display:display, name:display.project.name, runtime:display.project.runtime}); });
		for (_ in 0...8) { ashui.core.render.Offscreen.advance(.03); ashui.css.Css.setViewport(1280, 800); ashui.css.Css.update(); tree.flush(); tree.computeLayout(bench.node, 1280, 800); }
		bench.openProject();
		var found = bench.problems.get();
		check(found.length == 1 && found[0].file == null && found[0].message == "plugins.window: library not built yet", 'the file\'s problems reach Problems: ${found.length}');
		check(bench.runtime() == "caribou" || display.project.runtime == "caribou", "the project runs on Caribou");
		var css = ashui.css.Css;
		function settle(frames = 8):Void for (_ in 0...frames) { ashui.core.render.Offscreen.advance(.03); css.update(); tree.flush(); tree.computeLayout(bench.node, 1280, 800); }
		function node(selector:String):ashui.layout.Node {
			var ids = css.query(tree, bench.node.id, selector); check(ids.length == 1, 'missing or duplicate control: $selector');
			return new ashui.layout.Node(ids[0]);
		}
		bench.explorerPart.openExplorerFile(project + "/game.cbproj"); settle();
		check(bench.active.get() == rayde.ui.Workbench.SETTINGS && bench.settingsSection() == "build" && css.query(tree, bench.node.id, "#rayde-caribou-build").length == 1 && bench.editorFor(project + "/game.cbproj") == null, "Explorer opens the Caribou settings form");
		check(css.query(tree, bench.node.id, "#rayde-caribou-problems-section").length == 0, "the file's problems are in the Problems panel, not the form");
		bench.showPanel("problems"); settle();
		ashui.core.render.Snapshot.capture("caribou-problems-dark", tree, bench.node, 1280, 800, ashui.theme.ThemeState.get().color(Background).rgb());
		ashui.core.render.Snapshot.capture("caribou-settings-dark", tree, bench.node, 1280, 800, ashui.theme.ThemeState.get().color(Background).rgb());
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), Light); settle();
		ashui.core.render.Snapshot.capture("caribou-settings-light", tree, bench.node, 1280, 800, ashui.theme.ThemeState.get().color(Background).rgb());
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), Dark); settle();
		var name = node("#rayde-caribou-project-name"), box = tree.getScrolledBounds(name);
		ashui.input.Pointer.move(tree, box.x + box.width / 2, box.y + box.height / 2); ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); settle();
		ashui.ui.Input.at(tree, name.id).value.set("renamed"); settle(2);
		var mods = window.Modifiers.State(false, false, false, false, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown);
		for (state in [window.MouseElementState.Pressed, window.MouseElementState.Released])
			ashui.input.Keyboard.input(tree, window.KeyEvent.Input(Unidentified(Unidentified), window.Key.Named(Enter), None, Standard, state, false, Unavailable), mods);
		settle();
		check(sys.io.File.getContent(project + "/game.cbproj").indexOf('name = "renamed"') >= 0, "the name edit is written to the .cbproj");
		bench.buildChanged(); settle();
		check(bench.problems.get().length == 1, 'a reread replaces the project\'s problems rather than adding to them: ${bench.problems.get().length}');
		check(css.query(tree, bench.node.id, "#rayde-caribou-language-haxe").length == 1, "the languages are listed when the file has none");
		stop();
		Sys.println("Caribou workbench: the project file's problems are workspace problems, and its settings form edits the file");
	}

	public static function run():Void {
		var root = Sys.getCwd() + "bin/caribou-checks-" + Std.random(0x3fffffff), project = root + "/game", ws = root + "/ws";
		for (d in [root, project, ws, project + "/src"]) sys.FileSystem.createDirectory(d);
		var log = root + "/calls.log", fake = root + "/caribou";
		sys.io.File.saveContent(project + "/game.cbproj", '[project]\nname = "game"\nentry = "haxe:game.Main"\n');
		sys.io.File.saveContent(ws + "/ws.cbproj", '[workspace]\nmembers = ["../game"]\n');
		var projectJson = '{"dir":"$project","name":"game","entry":{"language":"haxe","module":"game.Main"},"languages":["haxe","lua"],"haxe":{"cwd":"$project","args":["-cp","src","-L","caribou","-D","caribou_guests","-main","game.Main","-hl","$project/target/game.hl"]},"problems":[{"key":"plugins.window","message":"library not built yet"},"a plain sentence"]}';
		var workspaceJson = '{"workspace":{"file":"$ws/ws.cbproj","dir":"$ws","members":["$project/game.cbproj"],"problems":[]},"members":[$projectJson],"project":null}';
		var findings = '{"severity":"error","source":"compile","message":"unexpected symbol","language":"lua","module":"game/hello","file":"$project/src/game/hello.lua","range":{"start":{"line":10,"column":26},"end":{"line":10,"column":31}}}\n'
			+ '{"severity":2,"source":"runtime","message":"slow frame"}\n{"serving":"http://127.0.0.1:1"}\nnot json\n';
		sys.io.File.saveContent(root + "/project.json", projectJson);
		sys.io.File.saveContent(root + "/workspace.json", workspaceJson);
		sys.io.File.saveContent(root + "/findings.jsonl", findings);
		sys.io.File.saveContent(fake, [
			"#!/bin/sh",
			"echo \"$@\" >> \"$FAKE_CARIBOU_LOG\"",
			"case \"$1\" in",
			"  project) case \"$2\" in *ws.cbproj) cat \"$FAKE_CARIBOU_DIR/workspace.json\";; *) cat \"$FAKE_CARIBOU_DIR/project.json\";; esac ;;",
			"  run|build) while [ \"$1\" != \"--diagnostics\" ]; do shift; done; cp \"$FAKE_CARIBOU_DIR/findings.jsonl\" \"$2\"; echo \"hello from guest\"; exit 0 ;;",
			"esac", ""].join("\n"));
		Sys.command("chmod", ["+x", fake]);
		Sys.putEnv("CARIBOU", fake); Sys.putEnv("FAKE_CARIBOU_LOG", log); Sys.putEnv("FAKE_CARIBOU_DIR", root);

		// The file kinds RayDE opens.
		check(ProjectFile.supported("game.cbproj") && ProjectFile.supported("/x/Game.CBPROJ"), "a .cbproj is a project file");

		// Opening: Caribou's reading, taken as it is.
		var opened = ProjectFile.read(project + "/game.cbproj");
		check(opened.kind == "caribou" && opened.runtime == "caribou" && opened.name == "game" && opened.runnable && opened.hxml == null, 'a Caribou project: ${opened.kind} ${opened.runtime} ${opened.name}');
		check(opened.args.join(" ") == '--cwd $project -cp src -L caribou -D caribou_guests -main game.Main -hl $project/target/game.hl', 'the Haxe arguments are Caribou\'s own: ${opened.args}');
		check(opened.problems.join("|") == "plugins.window: library not built yet|a plain sentence", 'problems of the file are kept: ${opened.problems}');
		var workspace = ProjectFile.read(ws + "/ws.cbproj");
		check(workspace.kind == "caribou" && !workspace.runnable && workspace.name == "ws" && workspace.members.join(",") == project + "/game.cbproj", 'a workspace lists its members: ${workspace.members}');
		check(sys.io.File.getContent(log).indexOf("project " + project + "/game.cbproj --json") >= 0, "RayDE asked Caribou to describe the project");

		// A Caribou that is missing or says no is a sentence, not a crash.
		Sys.putEnv("CARIBOU", root + "/nowhere");
		var failed:Null<String> = null; try ProjectFile.read(project + "/game.cbproj") catch (e:Dynamic) failed = Std.string(e);
		check(failed != null && failed.indexOf("caribou project failed: Command not found") == 0, 'a missing caribou is reported: $failed');
		Sys.putEnv("CARIBOU", fake);
		var json = ""; try CaribouProject.parse("{ not json") catch (e:Dynamic) json = Std.string(e);
		check(json.indexOf("not JSON") > 0, 'bad output is reported: $json');

		// The findings file.
		var parsed = CaribouDiagnostics.parse(findings);
		check(parsed.length == 2, 'only findings are findings: ${parsed.length}');
		check(parsed[0].severity == 1 && parsed[0].file == project + "/src/game/hello.lua" && parsed[0].range.start.line == 9 && parsed[0].range.start.character == 25 && parsed[0].range.end.character == 30, "a position is 1-based in Caribou and 0-based in RayDE");
		check(parsed[0].message == "[lua game/hello] unexpected symbol", 'the guest language leads the message: ${parsed[0].message}');
		check(parsed[1].severity == 2 && parsed[1].file == null && parsed[1].range == null, "a finding without a position is a workspace problem");

		// Run and Build go through the project file.
		var server = new CompilerServer(), display = Display.ofProject(server, project + "/game.cbproj"), runner = new Runner(display);
		function finish(what:String):Void {
			var end = haxe.Timer.stamp() + 20;
			while (runner.active() && haxe.Timer.stamp() < end) { runner.tick(); Sys.sleep(.02); }
			runner.tick();
			check(!runner.active(), 'the $what did not end: ${runner.state}');
		}
		check(runner.canBuild(), "a Caribou project can be built");
		runner.start(); finish("run");
		check(runner.state == "finished" && runner.exitCode == 0 && runner.console.indexOf("hello from guest") >= 0, 'run output: ${runner.state} ${runner.exitCode} ${runner.console}');
		check(runner.problems.length == 2 && runner.problems[0].file == project + "/src/game/hello.lua", 'the findings are the problems: ${runner.problems.length}');
		var calls = sys.io.File.getContent(log);
		check(calls.indexOf("run --diagnostics " + project + "/.rayde/run/diagnostics.jsonl " + project + "/game.cbproj") >= 0, 'run goes through the project file: $calls');
		runner.build(); finish("build");
		check(runner.state == "built" && runner.problems.length == 2, 'build: ${runner.state}');
		check(sys.io.File.getContent(log).indexOf("build --diagnostics " + project + "/.rayde/run/diagnostics.jsonl " + project + "/game.cbproj") >= 0, "build goes through the project file");
		var stopped = Display.ofProject(server, ws + "/ws.cbproj"), idle = new Runner(stopped);
		idle.start();
		check(idle.state == "failed" && idle.console.indexOf("no application entry point") >= 0, 'a workspace does not run: ${idle.state}');
		Sys.println("Caribou project: opened through caribou project --json, workspace members, missing tool, findings as problems, run and build through the project file");
	}
}
