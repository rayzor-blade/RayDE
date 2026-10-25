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
	/** The page's own files. A page saves them from `storage.onChange` and loads them with `storage.load` before `install`. */
	public static var storage(default, null):MemoryWorkspace;

	/** Where the program's own files are, standing for the directory a desktop install keeps beside the executable. */
	public static inline var PROGRAM = "/rayde";
	public static inline var HOME = "/home/web";
	/** The folder of the sample project when there is no session. */
	public static inline var SAMPLE = "/work";

	/**
	 * Makes `Fs` and `Procs` answer for a page. With a `session` its folder is the workspace; without one a small sample project is. Returns the path to open.
	 * `saved` is what the page kept of its own files from an earlier visit.
	 */
	public static function install(?session:SessionClient, ?saved:Array<{path:String, directory:Bool, bytes:Null<Bytes>}>):String {
		storage = new MemoryWorkspace();
		storage.load(builtIn());
		if (saved != null) storage.load(saved);
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
		if (!storage.exists(SAMPLE)) {
			storage.createDirectory(SAMPLE + "/src");
			storage.saveContent(SAMPLE + "/src/Main.hx", 'class Main {\n\tstatic function main() {\n\t\ttrace("Hello from RayDE in a page");\n\t}\n}\n');
			storage.saveContent(SAMPLE + "/build.hxml", "-cp src\n-main Main\n--interp\n");
		}
		Fs.current = routed;
		Procs.current = new NoLauncher();
		return SAMPLE + "/build.hxml";
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
