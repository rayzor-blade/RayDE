import rayde.ext.Connection;
import rayde.ext.Manifest;
import rayde.ext.Manager;
import rayde.project.ProjectFile;
import rayde.project.ProjectStarters;
import rayde.project.ProjectTemplates;

class ProjectStarterChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	static function rejects(action:Void->Void, message:String):Void {
		var rejected = false; try action() catch (_:Dynamic) rejected = true; check(rejected, message);
	}
	static function main():Void run();
	public static function run():Void {
		var root = Sys.getCwd() + "bin/starter-checks-" + Std.random(0x3fffffff), registry = new ProjectStarters();
		for (path in [root + "/app/console", root + "/user", root + "/workspace"]) sys.FileSystem.createDirectory(path);
		for (name in ["console.rayext", "main.rays"]) sys.io.File.copy("tests/fixtures/starters/console/" + name, root + "/app/console/" + name);
		var manager = new Manager(root + "/workspace", {builtins:root + "/app", user:root + "/user", defaultEvents:["onStartup"], restartLimit:3, restartWindow:60});
		var services:rayde.ext.Connection.WorkspaceServices = {
			root:() -> root + "/workspace", activeFile:() -> null, readFile:_ -> null, openFile:_ -> {}, writeFile:(_, _) -> {}, replay:_ -> null,
			registerStarter:registry.register, unregisterStarter:registry.unregister, releaseStarters:registry.release
		};
		function wait(done:Void->Bool):Void {
			var end = haxe.Timer.stamp() + 6;
			while (!done() && haxe.Timer.stamp() < end) { manager.tick(); Sys.sleep(.005); }
			check(done(), "Starter extension did not finish: " + [for (e in manager.extensions) e.output.join("\n")].join("\n"));
		}
		try {
			manager.discover(services, []); manager.start();
			check(registry.list().length == 0 && manager.extensions[0].activation == null, "Starter extension started before opening New Project");
			manager.newProject(); wait(() -> registry.list().length == 1);
			var entry = manager.extensions[0], manifest = entry.connection.manifest, owner = entry.connection.file, starter = registry.list()[0];
			check(entry.activation == "onNewProject" && manifest.problems.length == 0 && starter.id == "ext:console-starter:console", "Starter activation or id namespace was lost");
			var file = ProjectFile.create(root, "my-console", starter.id, starter.scaffold);
			check(ProjectFile.read(file).args.indexOf("Main") >= 0 && sys.io.File.getContent(root + "/my-console/src/Main.hx").indexOf("Hello, my-console!") >= 0, "Registered scaffold lost its files, entry or name placeholder");
			var run = rayde.run.RunConfigurations.load(root + "/my-console", "hl");
            check(run.framework == "ash" && run.flags.join(" ") == "--preset application" && run.arguments[0] == "starter argument", "RayScript starter lost its run configuration metadata");
            registry.unregister("another-owner", manifest, starter.id); check(registry.list().length == 1, "An extension unregistered another extension's starter");
			rejects(() -> registry.register("another-owner", manifest, {id:"console",name:"Impostor",files:[{path:"README.md",text:"unrelated"}]}), "Another host replaced an extension's starter");
			manager.command(entry.installed.id, "remove", {}); wait(() -> registry.list().length == 0);
			entry.connection.stop(); entry.connection.start(); wait(() -> registry.list().length == 1);
			manager.setDisabled(entry.installed.id, true); check(registry.list().length == 0, "Disabled extension retained starters");
			manager.setDisabled(entry.installed.id, false); manager.newProject(); wait(() -> registry.list().length == 1);
			var json:Dynamic = haxe.Json.parse(sys.io.File.getContent(manifest.file)); json.capabilities = [];
			sys.io.File.saveContent(manifest.file, haxe.Json.stringify(json)); entry.connection.useManifest(Manifest.read(manifest.file));
			check(registry.list().length == 0, "Revoked starter capability retained registrations");
			entry.connection.stop(); entry.connection.start();
			wait(() -> entry.output.join("\n").indexOf("Capability projects.register is not granted") >= 0);
			check(registry.list().length == 0, "A manifest without the starter capability registered a project");
			function definition(path:String):Dynamic return {id:"unsafe", name:"Unsafe", entry:"", files:[{path:path, text:"unchanged"}]};
			for (path in ["../outside", "/absolute", "C:/absolute", "src\\outside", "a/../../outside", "src//Main.hx", "./Main.hx", "folder./Main.hx"])
				rejects(() -> registry.register(owner, manifest, definition(path)), "Unsafe starter path accepted: " + path);
			for (files in [[{path:"Main.hx",text:"one"},{path:"main.hx",text:"two"}], [{path:"src",text:"file"},{path:"src/Main.hx",text:"child"}]])
				rejects(() -> registry.register(owner, manifest, {id:"conflict", name:"Conflicting", files:files}), "Starter file collision was accepted");
			rejects(() -> registry.register(owner, manifest, {id:"missing",name:"Missing",entry:"missing.hxml",files:[{path:"README.md",text:"hello"}]}), "Missing project entry was accepted");
			var folder = registry.register(owner, manifest, definition("nested/notes.txt"));
			var folderTemplate = registry.list()[0], workspace = ProjectFile.create(root, "folder-starter", folder, folderTemplate.scaffold);
			check(ProjectFile.read(workspace).kind == "folder" && sys.FileSystem.exists(workspace + "/nested/notes.txt"), "Custom non-Haxe starter did not open as a folder workspace");
			for (_ in 0...30) registry.register(owner, manifest, definition("nested/notes.txt"));
			check(registry.list().length == 1, "Re-registering a starter accumulated definitions");
			registry.release(owner); check(registry.list().length == 0, "Releasing an extension retained its file data");
			var bad = {entry:"", files:["../outside" => "text"]};
			rejects(() -> ProjectFile.create(root, "bad-worker", "custom", bad), "Creation worker accepted an unsafe scaffold");
			check(!sys.FileSystem.exists(root + "/bad-worker"), "Invalid scaffold left a destination directory");
			for (template in ProjectTemplates.all) check(template.target == (template.id == "javascript" ? "Web" : "Cross-platform"), "Inconsistent platform label for " + template.id);
		} catch (error:Dynamic) { manager.dispose(); throw error; }
		manager.dispose(); check(registry.list().length == 0, "Disposed manager retained starters");
		Sys.println("project starters: real RayScript registration, lazy activation, creation, placeholders, folder workspaces, path validation, replacement, capabilities, disable/restart and owner cleanup");
	}
}
