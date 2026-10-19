import rayde.ext.Connection;
import rayde.ext.HostBinary;
import rayde.ext.Manager;
import rayde.ext.Manifest;
import rayde.keys.Chord;
import rayde.keys.KeyBindings;
import rayde.settings.Extensions;
import rayde.settings.Store;

/** Exercises discovery and supervision with real host processes and no UI framework. */
class ExtensionManagerChecks {
	static function check(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	static function clean(path:String):Void {
		if (!sys.FileSystem.exists(path))
			return;
		if (sys.FileSystem.isDirectory(path)) {
			for (name in sys.FileSystem.readDirectory(path))
				clean(path + "/" + name);
			sys.FileSystem.deleteDirectory(path);
		} else
			sys.FileSystem.deleteFile(path);
	}

	static function write(path:String, text:String):Void {
		sys.FileSystem.createDirectory(haxe.io.Path.directory(path));
		sys.io.File.saveContent(path, text);
	}

	static function fixture(dir:String, id:String, ?events:Array<String>, marker = "", capabilities = true):String {
		var config:Dynamic = {
			id: id,
			name: id,
			main: "main.rays",
			capabilities: capabilities ? ["workspace.read"] : [],
			contributes: {commands: [{id: "describe", title: "Describe"}], keybindings: [{command: "describe", key: "mod+alt+d"}]}
		};
		if (events != null)
			config.activationEvents = events;
		var path = dir + "/" + id + "/" + id + ".rayext";
		write(path, haxe.Json.stringify(config));
		write(dir
			+ "/"
			+ id
			+ "/main.rays",
			"import rayde.workspace.readFile;\nregisterCommand('describe', (args) -> { trace('"
			+ marker
			+ "'); trace(await readFile('buffer')); });\nonHook('project.opened', e -> trace(e.root));");
		return path;
	}

	static function wait(manager:Manager, done:Void->Bool, message:String):Void {
		var end = haxe.Timer.stamp() + 5;
		while (!done() && haxe.Timer.stamp() < end) {
			manager.tick();
			Sys.sleep(.01);
		}
		check(done(), message);
	}

	public static function run():Void {
		var binary = HostBinary.find();
		if (binary == null)
			throw "extension manager checks need rayscript-host";
		var root = Sys.getCwd() + "bin/check-manager";
		clean(root);
		var app = root + "/app",
			userHome = root + "/user",
			user = userHome + "/.rayde/extensions",
			workspace = root + "/.rayde/extensions";
		fixture(app, "same", [], "built-in");
		fixture(user, "same", [], "user");
		fixture(workspace, "same", [], "workspace");
		fixture(app, "builtin", [], "builtin");
		fixture(user, "user", [], "user");
		fixture(workspace, "startup", null, "startup");
		fixture(workspace, "command", ["onCommand:describe"], "command");
		fixture(workspace, "view", ["onView:main"], "view");
		fixture(workspace, "match", ["workspaceContains:src/**/*.hx"], "matched");
		fixture(workspace, "nomatch", ["workspaceContains:outside/*.hx"], "not matched");
		fixture(workspace, "disabled", null, "disabled");
		fixture(workspace, "denied", ["onCommand:describe"], "denied", false);
		write(root + "/src/Main.hx", "class Main {}");
		write(root + "/.rayde/settings.json", '{"other":{"keep":true}}');
		Store.save(userHome, "extensions", {disabled: ["disabled"]});
		check(Extensions.disabled(root, userHome).join(",") == "disabled", "user disabled settings are read");
		Store.save(root, "extensions", {disabled: []});
		check(Extensions.disabled(root, userHome).length == 0, "workspace can override user disabled settings");
		var seen = Extensions.list(root, app, user);
		check(Lambda.count(seen, e -> e.id == "same") == 1 && Lambda.find(seen, e -> e.id == "same").scope == "Workspace",
			"workspace wins over user and built-in");
		clean(workspace + "/same");
		check(Lambda.find(Extensions.list(root, app, user), e -> e.id == "same").scope == "User", "user wins over built-in");
		check(Manager.glob("**/*.hx", "Main.hx")
			&& Manager.glob("src/**/*.hx", "src/nested/Main.hx")
			&& !Manager.glob("src/*.hx", "src/nested/Main.hx"),
			"activation glob segments");
		check(!Manager.contains(root, "../*.hx")
			&& !Manager.contains(root, root + "/src/Main.hx"), "activation paths stay relative to project root");
		var services:rayde.ext.Connection.WorkspaceServices = {
			readFile: _ -> "live buffer",
			activeFile: () -> null,
			root: () -> root,
			openFile: _ -> {},
			writeFile: (_, _) -> {},
			replay: name -> name == "project.opened" ? {
				root: root
			} : null
		};
		var manager = new Manager(root, {
			builtins: app,
			user: user,
			binary: binary,
			defaultEvents: ["onStartup"],
			restartLimit: 3,
			restartWindow: 60
		});
		manager.onDiscover = entry -> { if (entry.installed.id == "denied") entry.connection.onMessage = _ -> {}; };
		manager.discover(services, ["disabled"]);
		try {
			manager.start();
			check(manager.find("disabled").state == "stopped"
				&& !manager.find("disabled").connection.running(), "disabled extensions do not start");
			check(manager.find("nomatch").state == "inactive"
				&& manager.find("command").state == "inactive"
				&& manager.find("view").state == "inactive",
				"extensions wait for activation");
			check(manager.find("startup").state == "running"
				&& manager.find("match").state == "running", "startup and workspace matching activate");
			check(manager.find("same").state == "inactive", "explicit empty events do not use startup default");
			check(manager.command("command", "describe", {}), "command activates its extension");
			check(manager.view("view", "main"), "view activates its extension");
			check(manager.command("startup", "describe", {}), "two extensions can run commands with the same local id");
			check(Manager.commandKey("startup", "describe") != Manager.commandKey("command", "describe"), "key ids include the extension");
			wait(manager, () -> manager.find("startup").output.indexOf("live buffer") >= 0
				&& manager.find("command").output.indexOf("live buffer") >= 0,
				"services work without Studio");
			wait(manager, () -> manager.find("view").output.indexOf(root) >= 0, "late hook subscriptions replay workspace state");
			manager.command("denied", "describe", {});
			wait(manager, () -> manager.find("denied").output.join("\n").indexOf("Capability workspace.read") >= 0,
				"installed extensions enforce workspace capabilities");
			manager.setDisabled("command", true);
			check(!manager.find("command").connection.running() && !manager.command("command", "describe", {}),
				"disabling stops the host and blocks activation");
			manager.setDisabled("command", false);
			check(manager.find("command").state == "inactive"
				&& manager.command("command", "describe", {}), "enabling restores event activation");
		} catch (e:Dynamic) {
			manager.dispose();
			throw e;
		}
		manager.dispose();
		check(!Lambda.exists(manager.extensions, e -> e.connection.running()), "disposing stops all hosts");
		var devFile = fixture(root + "/development", "same", [], "development");
		var development = new Manager(root, {
			builtins: app,
			user: user,
			binary: binary,
			defaultEvents: ["onStartup"],
			restartLimit: 3,
			restartWindow: 60
		});
		development.discover(services, [], Manifest.read(devFile));
		try {
			development.start();
			check(Lambda.count(development.extensions, e -> e.installed.id == "same") == 1
				&& development.find("same").installed.scope == "Development",
				"the development project replaces the installed copy");
			check(development.find("same").connection.running(), "opening a development project starts it even with no activation event");
		} catch (e:Dynamic) {
			development.dispose();
			throw e;
		}
		development.dispose();

		var crashing = root + "/crashing";
		fixture(crashing + "/.rayde/extensions", "crash");
		var stub = root + "/exit-host.sh";
		write(stub, "#!/bin/sh\nexit 3\n");
		Sys.command("chmod", ["+x", stub]);
		var restarts = new Manager(crashing, {
			builtins: root + "/empty",
			user: root + "/empty",
			binary: stub,
			defaultEvents: ["onStartup"],
			restartLimit: 3,
			restartWindow: 60
		});
		restarts.discover(services, []);
		restarts.start();
		try {
			wait(restarts, () -> restarts.find("crash").restartBlocked, "an immediately exiting host stops after the restart limit");
			check(restarts.find("crash").restarts.length == 3
				&& restarts.find("crash").output.join("\n").indexOf("Restart limit reached") >= 0,
				"restart limit is logged");
			for (_ in 0...5)
				restarts.tick(haxe.Timer.stamp() + 120);
			check(!restarts.find("crash").connection.running() && restarts.find("crash").restarts.length == 3,
				"exhausted hosts stay down even after the window passes");
		} catch (e:Dynamic) {
			restarts.dispose();
			throw e;
		}
		restarts.dispose();
		write(root + "/.rayde/keybindings.json", '[{"command":"ext.describe","key":"mod+alt+9"},{"command":"ext.ambiguous","key":"mod+a"}]');
		var keys = KeyBindings.read(root, true);
		keys.setContributions([{command: "ext.command.describe", key: "mod+alt+d"}]);
		keys.migrateExtensions(root, [
			"ext.describe" => ["ext.command.describe"],
			"ext.ambiguous" => ["ext.a.ambiguous", "ext.b.ambiguous"]
		]);
		check(keys.commandFor(Chord.parse("mod+alt+9", true)) == "ext.command.describe"
			&& keys.of("ext.describe") == null, "unique saved keys migrate");
		check(keys.of("ext.ambiguous") != null, "ambiguous legacy keys are preserved without guessing an owner");
		keys.migrateExtensions(root, [
			"ext.describe" => ["ext.command.describe"],
			"ext.command.describe" => ["ext.other.command.describe"]
		]);
		check(keys.of("ext.command.describe") != null && keys.of("ext.other.command.describe") == null,
			"a qualified key is not mistaken for another extension's legacy id");

		keys.set("ext.command.describe", null);
		keys.save(root);
		var read = KeyBindings.read(root, true);
		read.setContributions([{command: "ext.command.describe", key: "mod+alt+d"}]);
		check(read.of("ext.command.describe") == null, "removing an extension default stays removed after reload");
		Sys.println("extension manager: precedence, activation, services, capabilities, disable, restart limit and key migration");
	}
}
