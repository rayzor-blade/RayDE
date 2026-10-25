package rayde.workspace;

import haxe.io.Bytes;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.SessionLauncher;
import rayde.workspace.session.SessionWorkspace;

/**
 * What RayDE runs on when it is in a page and not on a machine: browser storage for what belongs to the person and to the program
 * (settings, themes, built-in extensions), and, when there is one, a session for the workspace and its programs.
 */
class PageHost {
	public static var session(default, null):Null<SessionClient>;
	public static var bridge(default, null):Null<SessionClient>;

	/** Restores page storage and mounts the session selected by the browser's URL. */
	public static function open():Null<String> {
		#if wasm
		var channel = new rayde.workspace.session.BrowserChannel();
		bridge = SessionClient.over(channel);
		var entries:Array<Dynamic> = bridge.request("page.load").entries;
		var saved = [for (entry in entries) {path:(entry.path:String), directory:entry.directory == true,
			bytes:entry.directory == true ? null : haxe.crypto.Base64.decode(entry.data)}];
		session = bridge.remote ? bridge : null;
		var entry = install(session, saved, bridge.demo);
		if (session == null && bridge.demo && !hasSample(saved)) {
			var known = new Map<String, Bool>();
			for (file in saved) known.set(file.path, true);
			var entries = [for (file in storage.entries()) if (!known.exists(file.path) && (file.path == SAMPLE || StringTools.startsWith(file.path, SAMPLE + "/")))
				{path:file.path, directory:file.directory, data:file.directory ? null : haxe.crypto.Base64.encode(file.bytes)}];
			bridge.request("page.seed", {entries:entries});
		}
		storage.onChange = (path, kind) -> {
			if (!StringTools.startsWith(path, HOME + "/") && (session != null || !bridge.demo || !StringTools.startsWith(path, SAMPLE + "/"))) return;
			var found = storage.exists(path), directory = found && storage.isDirectory(path);
			bridge.notify("page.store", {entry:{path:path, remove:!found, directory:directory, data:!found || directory ? null : haxe.crypto.Base64.encode(storage.getBytes(path))}});
		};
		if (session != null && bridge.project != null && bridge.project != "") {
			var path = haxe.io.Path.normalize(session.root + "/" + bridge.project);
			if (rayde.files.FileOps.inside(session.root,path)) return path;
		}
		return entry;
		#else
		return install();
		#end
	}
	/** Account RPC travels through the browser agent; only the edge sees GitHub credentials. */
	public static function account(op:String, ?params:Dynamic):Dynamic {
		#if wasm
		if (bridge != null) {
			var response = bridge.request(op,params);
			if (response.result == null) throw "The account service returned an invalid response.";
			return response.result;
		}
		#end
		if (op == "account.status") return {user:null};
		throw "Connect this editor to the workspace service.";
	}
	/** The page's own files. A page saves them from `storage.onChange` and loads them with `storage.load` before `install`. */
	public static var storage(default, null):MemoryWorkspace;

	/** Where the program's own files are, standing for the directory a desktop install keeps beside the executable. */
	public static inline var PROGRAM = "/rayde";
	public static inline var HOME = "/home/web";
	/** The folder of the sample project when there is no session. */
	public static inline var SAMPLE = "/work";
	public static function workspaceRoot():String return session == null ? SAMPLE : session.root;
	public static function selected(path:String):Void {
		#if wasm
		if (bridge != null && rayde.files.FileOps.inside(workspaceRoot(),path))
			bridge.notify("page.project", {path:rayde.files.FileOps.relative(workspaceRoot(),path)});
		#end
	}

	/** The saved root is committed atomically with the initial sample files. Implicit parent directories do not count. */
	static function hasSample(saved:Null<Array<{path:String, directory:Bool, bytes:Null<Bytes>}>>):Bool
		return saved != null && Lambda.exists(saved, entry -> entry.path == SAMPLE && entry.directory);

	/**
	 * Makes `Fs` and `Procs` answer for a page. With a `session` its folder is the workspace; without one a small sample project is. Returns the path to open.
	 * `saved` is what the page kept of its own files from an earlier visit.
	 */
	public static function install(?session:SessionClient, ?saved:Array<{path:String, directory:Bool, bytes:Null<Bytes>}>, demo = true):Null<String> {
		storage = new MemoryWorkspace();
		storage.load(builtIn());
		if (saved != null) storage.load(demo && session == null ? saved : saved.filter(entry -> entry.path == HOME || StringTools.startsWith(entry.path,HOME + "/")));
		Sys.putEnv("HOME", HOME);
		Sys.putEnv("RAYDE_EXTENSIONS", PROGRAM + "/extensions");
		Sys.putEnv("RAYDE_THEMES", HOME + "/.rayde/themes");
		storage.createDirectory(HOME + "/.rayde/themes");
		var routed = new RoutedWorkspace(storage);
		if (session != null) {
			routed.mount(session.root, new SessionWorkspace(session));
			Fs.current = routed;
			Procs.current = session.exec ? new SessionLauncher(session) : new NoLauncher();
			return session.root;
		}
		if (!demo) { Fs.current = routed; Procs.current = new NoLauncher(); return null; }
		storage.createDirectory(SAMPLE);
		if (!hasSample(saved)) {
			if (!storage.exists(SAMPLE + "/src")) storage.createDirectory(SAMPLE + "/src");
			if (storage.isDirectory(SAMPLE + "/src") && !storage.exists(SAMPLE + "/src/Main.hx"))
				storage.saveContent(SAMPLE + "/src/Main.hx", 'class Main {\n\tstatic function main() {\n\t\ttrace("Hello from RayDE in browser");\n\t}\n}\n');
			if (!storage.exists(SAMPLE + "/build.hxml")) storage.saveContent(SAMPLE + "/build.hxml", "-cp src\n-main Main\n--interp\n");
		}
		Fs.current = routed;
		Procs.current = new NoLauncher();
		return storage.exists(SAMPLE + "/build.hxml") && !storage.isDirectory(SAMPLE + "/build.hxml") ? SAMPLE + "/build.hxml" : SAMPLE;
	}

	/** The themes and extension scripts and manifests that ship with RayDE; native libraries cannot run in a page and are left out. */
	static function builtIn():Array<{path:String, directory:Bool, bytes:Null<Bytes>}> {
		#if (wasm || rayde_page)
		// The mount paths are literals, as a macro needs, and are `PROGRAM`'s.
		return Embed.directory("themes", "/rayde/themes").concat(Embed.directory("extensions", "/rayde/extensions", ["natives"]));
		#else
		return [];
		#end
	}
}
