import rayde.project.ProjectFile;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.settings.RecentProjects;
import rayde.run.Runner;

class ProjectChecks {
	static function check(value:Bool, message:String):Void { if (!value) throw message; }
	static function rejects(action:Void->Void, message:String):Void {
		var failed = false; try action() catch (_:Dynamic) failed = true;
		check(failed, message);
	}
	static function main():Void run();
	public static function run():Void {
		var root = Sys.getCwd() + "bin/project checks λ-" + Std.random(0x3fffffff);
		sys.FileSystem.createDirectory(root);
		var entries = [for (kind in ["hxml", "haxelib", "rayzor"]) ProjectFile.create(root, "test-" + kind, kind)];
		var server = new CompilerServer();
		var folder = Display.ofProject(server, root);
		check(folder.cwd == root && folder.project.file == root && folder.project.kind == "folder", "Folder workspace lost its root or identity");
		check(folder.hxml == null && folder.args.length == 0 && !folder.project.runnable && folder.project.runtime == "", "Folder workspace assumes a Haxe build or runtime");
		sys.io.File.saveContent(root + "/build.hxml", "this is not a valid build\n");
		folder.reload();
		check(folder.hxml == null && folder.args.length == 0, "Folder workspace inferred a descriptor instead of retaining folder mode");
		for (entry in entries) {
			var project = ProjectFile.read(entry), display = Display.ofProject(server, entry);
			check(display.cwd == haxe.io.Path.directory(entry) && display.project.file == entry, "Project entry lost workspace identity");
			check(project.args.indexOf("src") >= 0, "Project omitted its source folder");
			RecentProjects.remember(entry, root);
		}
		check(RecentProjects.paths(root).length == 3, "Recent projects do not support each descriptor type");
		check(ProjectFile.read(entries[0]).hxml == entries[0], "HXML project lost its editable build file");
		check(ProjectFile.read(entries[1]).hxml == null && !ProjectFile.read(entries[1]).runnable, "Library pretends to be an application");
		var rayzor = ProjectFile.read(entries[2]);
		check(rayzor.runtime == "rayzor" && rayzor.main == rayzor.root + "/src/Main.hx" && rayzor.args.indexOf("Main") >= 0, "Rayzor template did not resolve its entry point");
		var original = sys.io.File.getContent(entries[0]);
		rejects(() -> ProjectFile.create(root, "test-hxml", "hxml"), "Creating a project overwrote an existing directory");
		check(sys.io.File.getContent(entries[0]) == original, "Creation failure changed an existing project");
		for (name in ["", "../outside", "bad/name", "space name", "1project"]) rejects(() -> ProjectFile.create(root, name, "hxml"), "Invalid project name accepted");
		var occupied = root + "/occupied"; sys.io.File.saveContent(occupied, "keep");
		rejects(() -> ProjectFile.create(root, "occupied", "hxml"), "Creation overwrote an existing file");
		check(sys.io.File.getContent(occupied) == "keep", "Existing file was modified");
		for (template in rayde.project.ProjectTemplates.all) {
			var entry = ProjectFile.create(root, "starter-" + template.id, template.id), project = ProjectFile.read(entry);
			check(project.args.indexOf("src") >= 0 && sys.FileSystem.exists(project.root + "/README.md"), "Template omitted its source root or getting-started instructions");
			if (["openfl", "flixel", "lime"].indexOf(template.id) >= 0) {
				var xml = Xml.parse(sys.io.File.getContent(project.root + "/project.xml")).firstElement();
				check(xml.nodeName == "project", "Framework template does not have a Lime project");
				var libraries = [for (lib in xml.elementsNamed("haxelib")) lib.get("name")];
				check(libraries.indexOf(template.id) >= 0 && project.args.indexOf(template.id) >= 0, "Framework dependency is missing from the build or editor manifest");
			}
			if (template.id == "flixel") check(sys.FileSystem.exists(project.root + "/src/PlayState.hx"), "HaxeFlixel template omitted its initial state");
			if (template.id == "javascript" || template.id == "heaps") check(sys.FileSystem.exists(project.root + "/index.html"), "Browser template omitted its launch page");
			var args = switch template.id {
				case "hxml": ["-cp", "src", "--run", "Main"];
				case "haxelib": ["-cp", "src", "--no-output", "Library"];
				case "javascript", "hashlink": ["build.hxml"];
				case _: null;
			};
			if (args != null) {
				var compile = new sys.io.Process("haxe", ["--cwd", project.root].concat(args)), errors = compile.stderr.readAll().toString(), status = compile.exitCode(); compile.close();
				check(status == 0, "Starter did not compile: " + template.id + "\n" + errors);
			}
		}
		rejects(() -> ProjectFile.create(root, "unknown", "missing-template"), "Unknown template was accepted");
		check(!sys.FileSystem.exists(root + "/unknown"), "Unknown template left a partial project");
		rejects(() -> ProjectFile.create(occupied, "new-project", "hxml"), "A file was accepted as the project parent");
		var libraryRoot = haxe.io.Path.directory(entries[1]);
		sys.io.File.saveContent(entries[1], '{"name":"library","classPath":"source code","dependencies":{"tink_core":"","format":"3.8.0"}}');
		sys.io.File.saveContent(libraryRoot + "/extraParams.hxml", "-D library_define\n");
		var library = Display.ofProject(server, entries[1]);
		check(library.args.indexOf("source code") >= 0 && library.args.indexOf("format:3.8.0") >= 0 && library.args.indexOf("library_define") >= 0, "Library paths, dependencies or extraParams were omitted");
		sys.io.File.saveContent(entries[1], '{"name":"changed","classPath":"src"}'); library.reload();
		check(library.project.name == "changed" && library.args.indexOf("src") >= 0, "Library metadata did not reload");
		sys.io.File.saveContent(entries[1], '{"name":"root-source","classPath":""}');
		check(ProjectFile.read(entries[1]).args[1] == ".", "Empty haxelib classPath did not select the project root");
		sys.io.File.saveContent(entries[2], "[project]\nname = 'Unicode λ'\nentry = 'src/Main.hx'\n[build]\nclass-paths = [\n 'src', # comment\n 'lib code',\n]\n[build.defines]\nfeature = true\nmessage = 'hello # world'\n");
		rayzor = ProjectFile.read(entries[2]);
		check(rayzor.name == "Unicode λ" && rayzor.args.indexOf("lib code") >= 0 && rayzor.args.indexOf("message=hello # world") >= 0, "TOML multiline arrays, Unicode, comments or defines were misread");
		var nested = rayzor.root + "/examples/sample-app";
		sys.FileSystem.createDirectory(nested);
		sys.io.File.saveContent(nested + "/Main.hx", "class Main { static function main() {} }\n");
		sys.io.File.saveContent(nested + "/rayzor.toml", "[project]\nentry='Main.hx'\n[build]\nclass-paths=['.', '../../']\n");
		var application = ProjectFile.read(nested + "/rayzor.toml"), main = application.args.indexOf("-main");
		check(main >= 0 && application.args[main + 1] == "Main", "Overlapping class paths did not use the first matching source root");
		sys.FileSystem.createDirectory(rayzor.root + "/config");
		sys.io.File.saveContent(rayzor.root + "/config/editor.hxml", "-cp ../src\n-main Main\n");
		sys.io.File.saveContent(entries[2], "[project]\nname='delegated'\nhxml='config/editor.hxml'\n");
		rayzor = ProjectFile.read(entries[2]);
		check(rayzor.root == haxe.io.Path.directory(entries[2]) && rayzor.hxml == rayzor.root + "/config/editor.hxml" && rayzor.args[0] == "--cwd", "Delegated HXML lost workspace root or compiler working directory");
		check(!rayzor.runnable, "An HXML-only Rayzor manifest offers Run without a source entry");
		sys.io.File.saveContent(entries[2], "[project]\nname='no-paths'\n");
		check(ProjectFile.read(entries[2]).args.length == 0, "Rayzor manifest inferred an undeclared src directory");
		sys.io.File.saveContent(entries[2], "[workspace]\nmembers=[]\n[project]\nentry='src/Main.hx'\n[build]\nclass-paths=['src']\n");
		var workspace = ProjectFile.read(entries[2]);
		check(!workspace.runnable && workspace.main == null && workspace.args.length == 0, "Workspace did not take precedence over project/build fields");
		sys.io.File.saveContent(entries[2], "[workspace]\n");
		rejects(() -> ProjectFile.read(entries[2]), "Workspace without required members array was accepted");
		sys.io.File.saveContent(entries[2], "[project\nname=no");
		rejects(() -> ProjectFile.read(entries[2]), "Malformed TOML was accepted");
		sys.io.File.saveContent(entries[1], "{broken");
		rejects(() -> ProjectFile.read(entries[1]), "Malformed JSON was accepted");
		var libraryRun = new Runner(library); libraryRun.start();
		check(libraryRun.state == "failed" && libraryRun.console.indexOf("entry point") >= 0 && !server.running(), "Library Run tried to compile an application");
		var fake = root + "/fake-rayzor", record = root + "/run-record";
		sys.io.File.saveContent(fake, "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > '" + record + "'\n");
		Sys.command("chmod", ["+x", fake]);
		sys.io.File.saveContent(entries[2], "[project]\nentry='src/Main.hx'\n[build]\nclass-paths=['src']\n");
		var old = Sys.getEnv("RAYZOR_LSP"); Sys.putEnv("RAYZOR_LSP", fake);
		var run = new Runner(Display.ofProject(server, entries[2])); run.start();
		var deadline = haxe.Timer.stamp() + 5;
		while (run.active() && haxe.Timer.stamp() < deadline) { run.tick(); Sys.sleep(.005); }
		Sys.putEnv("RAYZOR_LSP", old ?? "");
		check(run.state == "finished" && sys.io.File.getContent(record) == haxe.io.Path.directory(entries[2]) + "\nrun\n" && !server.running(), "Rayzor project did not use its runtime and project directory");
		server.stop();
		Sys.println("projects: ecosystem starters, core-target compilation, exclusive creation, manifest parsing, dependencies, nested HXML, reload, recents and runtime routing");
	}
}
