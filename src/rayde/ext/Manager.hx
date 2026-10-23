package rayde.ext;

import rayde.ext.Connection.WorkspaceServices;
import rayde.settings.Extensions;
import rayde.settings.Extensions.Extension;

/** Runtime policy and install locations supplied by the application. */
typedef ManagerOptions = {
	builtins:String,
	user:String,
	defaultEvents:Array<String>,
	restartLimit:Int,
	restartWindow:Float,
	?trustHome:String
};

/** An installed extension and its host, activation and restart state. */
class ManagedExtension {
	public final installed:Extension;
	public final connection:Connection;
	public var disabled = false;
	public var activation:Null<String>;
	public var state = "inactive";
	public final output:Array<String> = [];
	public final outputKinds:Array<String> = [];
	public var restarts:Array<Float> = [];
	public var restartBlocked = false;
	public var onDisabled:Null<Bool->Void>;

	public function new(installed:Extension, connection:Connection) {
		this.installed = installed;
		this.connection = connection;
	}

	public function log(text:String, kind = "info"):Void {
		output.push(text);
		outputKinds.push(kind);
		if (output.length > 1000) {
			output.shift();
			outputKinds.shift();
		}
	}
}

/** Discovers, activates and supervises extension runtimes independently of the Studio. */
class Manager {
	public final extensions:Array<ManagedExtension> = [];
	public var onChanged:Null<Void->Void>;
	public var onDiscover:Null<ManagedExtension->Void>;
	public var onOutput:Null<ManagedExtension->Void>;
	public final root:String;

	final options:ManagerOptions;
	var disposed = false;
	var started = false;

	public function new(root:String, options:ManagerOptions) {
		this.root = root;
		this.options = options;
	}

	public static function commandKey(id:String, command:String):String
		return 'ext.$id.$command';

	public function discover(services:WorkspaceServices, disabled:Array<String>, ?development:Manifest):Void {
		var found = Extensions.list(root, options.builtins, options.user);
		if (development != null) {
			found = [for (e in found) if (e.id != development.id) e];
			found.push({
				id: development.id,
				name: development.name,
				version: development.version,
				description: development.description,
				path: development.root,
				scope: "Development",
				manifest: development,
				problem: development.problems.length == 0 ? null : development.problems[0]
			});
		}
		for (e in found) {
			var m = e.manifest;
			var c = new Connection(m.mainPath(), () -> sys.io.File.getContent(m.mainPath()), m);
			c.services = services;
			c.nativeAllowed = manifest -> e.scope == "Built-in" || NativeTrust.allApproved(manifest, options.trustHome);
			var entry = new ManagedExtension(e, c);
			entry.disabled = disabled.indexOf(e.id) >= 0;
			if (entry.disabled || e.problem != null)
				entry.state = "stopped";
			else if (!c.nativeAllowed(m))
				entry.state = "blocked";
			extensions.push(entry);
			if (onDiscover != null)
				onDiscover(entry);
			var previousLog = c.onEntry;
			c.onEntry = (list, entryLog) -> {
				if (previousLog != null)
					previousLog(list, entryLog);
				if (list == "console") {
					entry.log(entryLog.text, entryLog.kind);
					if (onOutput != null)
						onOutput(entry);
				}
			};
			var previousState = c.onState;
			c.onState = state -> {
				if (previousState != null)
					previousState(state);
				if (state == "running")
					entry.state = "running";
				else if (state == "blocked") {
					entry.state = "blocked";
					if (entry.onDisabled != null) entry.onDisabled(true);
				} else if (entry.activation != null || entry.disabled)
					entry.state = "stopped";
				changed();
			};
		}
	}

	public function find(id:String):Null<ManagedExtension>
		return Lambda.find(extensions, e -> e.installed.id == id);

	function events(e:ManagedExtension):Array<String>
		return e.connection.manifest.activationEvents ?? options.defaultEvents;

	public function start():Void {
		if (disposed)
			return;
		started = true;
		for (e in extensions)
			activateWorkspace(e);
	}

	function activateWorkspace(e:ManagedExtension):Void {
		if (e.disabled || e.installed.problem != null)
			return;
		if (e.installed.scope == "Development") {
			activate(e, "development");
			return;
		}
		for (event in events(e)) {
			if (event == "onStartup" || StringTools.startsWith(event, "workspaceContains:") && contains(root, event.substr(18))) {
				activate(e, event);
				return;
			}
		}
	}

	function activate(e:ManagedExtension, event:String):Bool {
		if (disposed || e.disabled || e.installed.problem != null)
			return false;
		if (!e.connection.nativeAllowed(e.connection.manifest)) {
			e.state = "blocked";
			return false;
		}
		if (e.connection.running())
			return true;
		if (e.activation != null)
			return false;
		e.activation = event;
		e.log('Activated by $event');
		if (onOutput != null)
			onOutput(e);
		e.connection.start();
		changed();
		return e.connection.running();
	}

	public function command(id:String, command:String, args:Dynamic):Bool {
		var e = find(id);
		if (e == null || e.disabled)
			return false;
		if (!e.connection.running()) {
			var event = 'onCommand:$command';
			var matches = Lambda.exists(events(e), p -> StringTools.startsWith(p, "onCommand:") && glob(p.substr(10), command));
			if (!matches || !activate(e, event))
				return false;
		}
		e.connection.command(command, args);
		return true;
	}

	public function view(id:String, view:String):Bool {
		var e = find(id);
		if (e == null || e.disabled)
			return false;
		if (e.connection.running())
			return true;
		var event = 'onView:$view';
		return events(e).indexOf(event) >= 0 && activate(e, event);
	}

	public function newProject():Void {
		for (entry in enabled()) if (events(entry).indexOf("onNewProject") >= 0) activate(entry, "onNewProject");
	}

	public function codeActions(language:String):Void {
		var event = "onCodeActions:" + language;
		for (entry in enabled()) if (events(entry).indexOf(event) >= 0) activate(entry, event);
	}

	public function setDisabled(id:String, disabled:Bool):Void {
		var e = find(id);
		if (e == null || e.disabled == disabled)
			return;
		e.disabled = disabled;
		e.restartBlocked = false;
		e.restarts = [];
		e.activation = null;
		e.connection.stop();
		if (e.onDisabled != null)
			e.onDisabled(disabled);
		e.state = disabled ? "stopped" : e.connection.nativeAllowed(e.connection.manifest) ? "inactive" : "blocked";
		e.log(disabled ? "Disabled" : "Enabled");
		if (!disabled && started)
			activateWorkspace(e);
		if (onOutput != null)
			onOutput(e);
		changed();
	}

	public function nativeApproved(e:ManagedExtension, name:String):Bool {
		var m = e.connection.manifest, library = Lambda.find(m.natives, n -> n.name == name);
		return library != null && (e.installed.scope == "Built-in" || NativeTrust.approved(m, library, options.trustHome));
	}

	public function setNativeApproved(id:String, name:String, allow:Bool):Void {
		var e = find(id);
		if (e == null || e.installed.scope == "Built-in") return;
		var m = e.connection.manifest, library = Lambda.find(m.natives, n -> n.name == name);
		if (library == null || !NativeTrust.set(m, library, allow, options.trustHome)) {
			e.log("Cannot save native approval.", "error");
			changed();
			return;
		}
		var previous = e.activation;
		e.connection.stop();
		e.activation = null;
		if (!allow && e.onDisabled != null) e.onDisabled(true);
		e.restarts = [];
		e.restartBlocked = false;
		e.state = !e.disabled && !e.connection.nativeAllowed(m) ? "blocked" : "inactive";
		e.log((allow ? "Approved native library " : "Revoked native library ") + name);
		if (!e.disabled && started) {
			if (previous != null && e.connection.nativeAllowed(m)) activate(e, previous); else activateWorkspace(e);
		}
		if (onOutput != null) onOutput(e);
		changed();
	}

	public function tick(?now:Float, pollConnections = true):Void {
		if (disposed)
			return;
		var time = now ?? haxe.Timer.stamp();
		for (e in extensions) {
			if (pollConnections)
				e.connection.tick();
			if (!e.disabled && e.activation != null && e.connection.state == "exited" && !e.restartBlocked) {
				e.restarts = [for (t in e.restarts) if (time - t < options.restartWindow) t];
				if (e.restarts.length >= options.restartLimit) {
					e.restartBlocked = true;
					e.log('Restart limit reached (${options.restartLimit} in ${options.restartWindow} seconds); extension stopped.', "error");
				} else {
					e.restarts.push(time);
					e.log('Restarting extension (${e.restarts.length}/${options.restartLimit})', "warning");
					e.connection.start();
				}
				if (onOutput != null)
					onOutput(e);
				changed();
			}
		}
	}

	public function enabled():Array<ManagedExtension>
		return [for (e in extensions) if (!e.disabled && e.installed.problem == null) e];

	function changed():Void {
		if (onChanged != null)
			onChanged();
	}

	public function dispose():Void {
		disposed = true;
		for (e in extensions)
			e.connection.stop();
	}

	/** Matches a slash-separated relative path: * and ? stay within a segment; ** crosses folders. */
	public static function glob(pattern:String, path:String):Bool {
		var out = "^", i = 0;
		while (i < pattern.length) {
			var ch = pattern.charAt(i++);
			switch ch {
				case "*":
					if (pattern.charAt(i) == "*") {
						i++;
						if (pattern.charAt(i) == "/") {
							i++;
							out += "(?:.*/)?";
						} else
							out += ".*";
					} else
						out += "[^/]*";
				case "?":
					out += "[^/]";
				case _:
					out += ~/[^A-Za-z0-9_\/-]/.match(ch) ? "\\" + ch : ch;
			}
		}
		return new EReg(out + "$", "").match(path);
	}

	public static function contains(root:String, pattern:String):Bool {
		if (pattern == "" || haxe.io.Path.isAbsolute(pattern) || pattern.split("/").indexOf("..") >= 0)
			return false;
		if (pattern.indexOf("*") < 0 && pattern.indexOf("?") < 0)
			return sys.FileSystem.exists(haxe.io.Path.join([root, pattern]));
		var visited = new Map<String, Bool>();
		function scan(dir:String, relative:String):Bool {
			var real = sys.FileSystem.fullPath(dir);
			if (visited.exists(real))
				return false;
			visited.set(real, true);
			for (name in sys.FileSystem.readDirectory(dir)) {
				var path = haxe.io.Path.join([dir, name]),
					rel = relative == "" ? name : relative + "/" + name;
				if (glob(pattern, rel))
					return true;
				if (name != ".git" && name != ".rayde" && name != "node_modules" && sys.FileSystem.isDirectory(path))
					try {
						if (scan(path, rel))
							return true;
					} catch (_:Dynamic) {}
			}
			return false;
		}
		return try scan(root, "") catch (_:Dynamic) false;
	}
}
