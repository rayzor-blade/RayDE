import rayde.ext.Connection;
import rayde.ext.Manager;
import rayde.ext.Manifest;
import rayde.ext.NativeTrust;
import rayde.keys.Chord;
import rayde.keys.KeyBindings;
import rayde.settings.Extensions;
import rayde.settings.Store;

/** Exercises discovery and supervision with embedded host VMs and no UI framework. */
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
			var denied = manager.find("denied"), deniedIndex = denied.output.indexOf(Lambda.find(denied.output, text -> text.indexOf("Capability workspace.read") >= 0));
			check(denied.outputKinds[deniedIndex] == "error", "extension errors retain their Output severity");
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
		var restarts = new Manager(crashing, {
			builtins: root + "/empty",
			user: root + "/empty",
			defaultEvents: ["onStartup"],
			restartLimit: 3,
			restartWindow: 60
		});
		restarts.discover(services, []);
		var crashingConnection = restarts.find("crash").connection;
		crashingConnection.onStart = () -> crashingConnection.send({t: "shutdown"});
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
		nativeChecks(root + "/native-checks", services);
		var settingsFile = fixture(root + "/settings-test", "settings", [], "", false);
		var config:Dynamic = haxe.Json.parse(sys.io.File.getContent(settingsFile));
		config.contributes.configuration = {properties: {"fixture.strategy": {type:"string", "default":"ff-only"}}};
		write(settingsFile, haxe.Json.stringify(config));
		var source = "import rayde.settings.get; import rayde.window.notify; registerCommand('read', () -> trace(await get('fixture.strategy', 'fallback'))); registerCommand('alert', () -> await notify('fixture notification', 'error'));";
		var connection = new Connection(settingsFile, () -> source, Manifest.read(settingsFile)), seen:Array<String> = [];
		connection.services = services;
		connection.onEntry = (_, entry) -> seen.push(entry.text);
		function reads(expected:String):Void {
			connection.command("read", null);
			var end = haxe.Timer.stamp() + 5;
			while (seen.indexOf(expected) < 0 && haxe.Timer.stamp() < end) { connection.tick(); Sys.sleep(.01); }
			check(seen.indexOf(expected) >= 0, 'extension settings read $expected without a workspace capability: ' + seen.join(" | "));
		}
		try {
			connection.start();
			reads("ff-only");
			Store.save(root, "extension.other", {"fixture.strategy":"other extension"});
			seen = []; reads("ff-only");
			Store.save(root, "extension.settings", {"fixture.strategy":"merge"});
			reads("merge");
			var notices:Array<String> = [];
			services.notify = (id, title, message, kind) -> notices.push(id + ":" + kind + ":" + message);
			connection.command("alert", null);
			var end = haxe.Timer.stamp() + 5;
			while (notices.length == 0 && haxe.Timer.stamp() < end) { connection.tick(); Sys.sleep(.01); }
			check(notices.join("") == "settings:error:fixture notification" && seen.indexOf("fixture notification") >= 0,
				"notifications route to the UI and extension Output without a workspace capability");
		} catch (failure:Dynamic) { connection.stop(); throw failure; }
		connection.stop();
		Sys.println("extension manager: precedence, activation, services, capabilities, disable, restart limit and key migration");
	}

	static function nativeChecks(root:String, services:rayde.ext.Connection.WorkspaceServices):Void {
		var home = root + "/home", app = root + "/app", workspace = root + "/.rayde/extensions";
		function nativeFixture(dir:String, id:String, hash:String, two = false):Manifest {
			var file = fixture(dir, id);
			var config:Dynamic = haxe.Json.parse(sys.io.File.getContent(file));
			config.capabilities = two ? ["native:example", "native:second"] : ["native:example"];
			config.natives = {example: {path: "natives/library", sha256: hash}};
			if (two) Reflect.setField(config.natives, "second", {path: "natives/second", sha256: hash});
			write(file, haxe.Json.stringify(config));
			write(dir + "/" + id + "/main.rays", "trace('native ready');");
			write(dir + "/" + id + "/natives/library", "native fixture");
			write(dir + "/" + id + "/natives/second", "native fixture");
			return Manifest.read(file);
		}
		var hash = haxe.crypto.Sha256.encode("native fixture");
		var manifest = nativeFixture(workspace, "untrusted", hash, true);
		var builtin = nativeFixture(app, "builtin", hash);
		var mismatch = nativeFixture(app, "mismatch", haxe.crypto.Sha256.encode("different bytes"));
		check(manifest.problems.length == 0 && manifest.natives.length == 2, "native declarations parse");
		Store.save(root, "extensions", {nativeApprovals: [{id: manifest.id, extension: manifest.file, library: "example", path: "natives/library", sha256: hash}]});
		check(!NativeTrust.approved(manifest, manifest.natives[0], home), "workspace settings cannot grant native execution");
		var manager = new Manager(root, {builtins: app, user: root + "/empty", trustHome: home,
			defaultEvents: ["onStartup"], restartLimit: 3, restartWindow: 60});
		manager.discover(services, []);
		try {
			manager.start();
			var entry = manager.find("untrusted");
			check(entry.state == "blocked" && !entry.connection.running(), "native extension waits for approval");
			manager.setNativeApproved("untrusted", "example", true);
			check(!entry.connection.running(), "every declared library needs approval");
			manager.setNativeApproved("untrusted", "second", true);
			wait(manager, () -> entry.output.indexOf("native ready") >= 0, "approval starts extension and host accepts hashes");
			check(NativeTrust.allApproved(manifest, home), "approval persists in user settings");
			wait(manager, () -> manager.find("builtin").output.indexOf("native ready") >= 0, "built-ins are pre-approved");
			wait(manager, () -> manager.find("mismatch").connection.state == "blocked", "built-ins still enforce hashes");
			check(manager.find("mismatch").restarts.length == 0 && manager.find("mismatch").output.join("\n").indexOf("SHA-256 mismatch") >= 0,
				"invalid native grants report the reason without a crash restart loop");
			var modified:Dynamic = haxe.Json.parse(sys.io.File.getContent(manifest.file));
			modified.natives.example.sha256 = haxe.crypto.Sha256.encode("edited manifest");
			write(manifest.file, haxe.Json.stringify(modified));
			entry.connection.useManifest(Manifest.read(manifest.file));
			check(!entry.connection.running() && entry.state == "blocked", "manifest edits stop a host whose approval no longer matches");
			write(manifest.file, haxe.Json.stringify({id: manifest.id, main: "main.rays", capabilities: manifest.capabilities,
				natives: {example: {path: "natives/library", sha256: hash}, second: {path: "natives/second", sha256: hash}}}));
			entry.connection.useManifest(Manifest.read(manifest.file));
			entry.connection.start();
			var restored = sys.io.File.getContent(manifest.file);
			write(manifest.file, haxe.Json.stringify({id: manifest.id, main: "main.rays"}));
			entry.connection.useManifest(Manifest.read(manifest.file));
			check(!entry.connection.running() && entry.connection.state == "stopped", "removing native declarations stops the host holding obsolete grants");
			write(manifest.file, restored);
			entry.connection.useManifest(Manifest.read(manifest.file));
			entry.connection.start();
			var cleaned = false;
			entry.onDisabled = _ -> cleaned = true;
			manager.setNativeApproved("untrusted", "example", false);
			check(!entry.connection.running() && entry.state == "blocked" && cleaned, "revocation stops host and clears contributions");
			check(!NativeTrust.approved(manifest, manifest.natives[0], home), "revocation persists");
			NativeTrust.set(manifest, manifest.natives[0], true, home);
			var config:Dynamic = haxe.Json.parse(sys.io.File.getContent(manifest.file));
			config.natives.example.sha256 = haxe.crypto.Sha256.encode("changed");
			write(manifest.file, haxe.Json.stringify(config));
			var changed = Manifest.read(manifest.file);
			check(!NativeTrust.approved(changed, changed.natives[0], home), "hash changes require approval again");
			config.natives.example.sha256 = hash;
			config.natives.example.path = "natives/renamed";
			write(manifest.file, haxe.Json.stringify(config));
			changed = Manifest.read(manifest.file);
			check(!NativeTrust.approved(changed, changed.natives[0], home), "path changes require approval again");
			check(NativeTrust.set(changed, changed.natives[0], true, home) && !NativeTrust.approved(manifest, manifest.natives[0], home),
				"a new approval replaces the previous path and hash for that library");
			NativeTrust.set(changed, changed.natives[0], false, home);
			write(workspace + "/moved/main.rays", "");
			write(workspace + "/moved/untrusted.rayext", sys.io.File.getContent(manifest.file));
			changed = Manifest.read(workspace + "/moved/untrusted.rayext");
			check(!NativeTrust.approved(changed, changed.natives[0], home), "another extension location cannot inherit approval");
			for (bad in ["../escape", "/absolute", "a\\b", "C:/library", "a/./library"]) {
				config.natives.example.path = bad;
				write(manifest.file, haxe.Json.stringify(config));
				check(Manifest.read(manifest.file).problems.length > 0, "native paths must be confined relative paths");
			}
			config.natives.example.path = "natives/library";
			config.capabilities = [];
			write(manifest.file, haxe.Json.stringify(config));
			check(Manifest.read(manifest.file).problems.join(" ").indexOf("requires capability") >= 0, "native capability is required");
		} catch (error:Dynamic) {
			manager.dispose();
			throw error;
		}
		manager.dispose();
		Sys.println("native trust: user approvals, path/hash identity, per-library grants, revocation, built-in validation");
	}
}
