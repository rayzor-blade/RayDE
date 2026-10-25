import haxe.io.Bytes;
import rayde.workspace.Fs;
import rayde.workspace.Launcher;
import rayde.workspace.LocalLauncher;
import rayde.workspace.Procs;
import rayde.workspace.RoutedWorkspace;
import rayde.workspace.PageHost;
import rayde.workspace.Program;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.SessionLauncher;
import rayde.workspace.session.SessionWorkspace;
import rayde.workspace.LocalWorkspace;
import rayde.workspace.MemoryWorkspace;
import rayde.workspace.Workspace;

/**
 * What a `Workspace` must do, whatever holds the files: the local filesystem and the in-memory one answer alike,
 * and so must the provider that asks a session.
 */
class WorkspaceChecks {
	static function check(ok:Bool, what:String):Void if (!ok) throw what;

	static function fails(call:Void->Void):Bool {
		try call() catch (_:Dynamic) return true;
		return false;
	}

	/** `root` is a directory the provider may use, empty or absent. */
	public static function conform(ws:Workspace, root:String, label:String):Void {
		var at = (name:String) -> root + "/" + name;
		ws.createDirectory(at("src/pkg"));
		check(ws.exists(at("src/pkg")) && ws.isDirectory(at("src/pkg")) && !ws.isDirectory(at("missing")) && !ws.exists(at("missing")), '$label: directories exist after createDirectory');
		ws.createDirectory(at("src/pkg"));
		ws.saveContent(at("src/pkg/A.hx"), "class A {}\n");
		ws.saveContent(at("src/B.hx"), "λ");
		check(ws.getContent(at("src/pkg/A.hx")) == "class A {}\n" && ws.getContent(at("src/B.hx")) == "λ", '$label: content round trips, UTF-8 included');
		check(!ws.isDirectory(at("src/B.hx")) && ws.exists(at("src/B.hx")), '$label: a file is not a directory');
		var names = ws.readDirectory(at("src"));
		names.sort((a, b) -> a < b ? -1 : a > b ? 1 : 0);
		check(names.join(",") == "B.hx,pkg", '$label: directory entries are names: $names');
		var bytes = Bytes.alloc(4);
		for (i in 0...4) bytes.set(i, [0, 255, 10, 13][i]);
		ws.saveBytes(at("bin.dat"), bytes);
		check(ws.getBytes(at("bin.dat")).compare(bytes) == 0, '$label: bytes round trip');
		check(ws.stat(at("bin.dat")).size == 4 && ws.stat(at("src/B.hx")).size == 2, '$label: stat gives the size in bytes');
		check(Math.abs(Date.now().getTime() - ws.stat(at("bin.dat")).mtime.getTime()) < 120000, '$label: stat gives a modification time near now');
		check(ws.readFrom(at("bin.dat"), 2).compare(bytes.sub(2, 2)) == 0 && ws.readFrom(at("bin.dat"), 4).length == 0, '$label: readFrom gives what follows an offset');
		ws.copy(at("src/B.hx"), at("src/C.hx"));
		check(ws.getContent(at("src/C.hx")) == "λ" && ws.exists(at("src/B.hx")), '$label: copy keeps the source');
		check(fails(() -> ws.rename(at("src/C.hx"), at("nowhere/D.hx"))) && ws.exists(at("src/C.hx")), '$label: rename does not create a missing destination directory');
		ws.createDirectory(at("moved"));
		ws.rename(at("src/C.hx"), at("moved/D.hx"));
		check(!ws.exists(at("src/C.hx")) && ws.getContent(at("moved/D.hx")) == "λ", '$label: rename moves a file');
		check(fails(() -> ws.getContent(at("nothing.txt"))), '$label: reading a missing file fails');
		check(fails(() -> ws.readDirectory(at("src/B.hx"))), '$label: reading a file as a directory fails');
		check(fails(() -> ws.deleteDirectory(at("src"))), '$label: a directory with files in it is not deleted');
		ws.deleteFile(at("src/B.hx"));
		ws.deleteFile(at("src/pkg/A.hx"));
		ws.deleteDirectory(at("src/pkg"));
		ws.deleteDirectory(at("src"));
		check(!ws.exists(at("src")), '$label: emptied directories delete');
		ws.deleteFile(at("moved/D.hx"));
		ws.deleteDirectory(at("moved"));
		ws.deleteFile(at("bin.dat"));
	}

	/** What a `Launcher` must do: a program's output, exit code, input and ending. */
	public static function conformLauncher(launcher:Launcher, label:String):Void {
		var finished = launcher.start("/bin/sh", ["-c", "echo out; echo err 1>&2; exit 3"]);
		check(finished.stdout.readAll().toString() == "out\n" && finished.stderr.readAll().toString() == "err\n", '$label: stdout and stderr are separate');
		check(finished.exitCode() == 3, '$label: exitCode gives the exit code');
		finished.close();
		var echo = launcher.start("/bin/cat", []);
		echo.stdin.writeString("typed\n");
		echo.stdin.close();
		check(echo.stdout.readAll().toString() == "typed\n" && echo.exitCode() == 0, '$label: stdin reaches the program');
		echo.close();
		var long = launcher.start("/bin/sleep", ["30"]);
		check(long.exitCode(false) == null, '$label: a running program has no exit code yet');
		long.kill();
		check(long.exitCode() != 0, '$label: a killed program ends without success');
		long.close();
		var missing:Int = try launcher.start("/nonexistent/program", []).exitCode() catch (_:Dynamic) -1;
		check(missing != 0, '$label: a missing program fails to start or ends unsuccessfully');
	}

	public static function run():Void {
		conformLauncher(new LocalLauncher(), "local launcher");
		runThroughProcs();
		var local = Sys.getCwd() + "bin/workspace-checks-" + Std.random(0x3fffffff);
		sys.FileSystem.createDirectory(local);
		conform(new LocalWorkspace(), local, "local");
		sys.FileSystem.deleteDirectory(local);
		conform(new MemoryWorkspace(), "/work", "memory");
		againstSession();
		routing();

		// RayDE's own code reaches files through `Fs`: it follows whatever is current, and the machine's disk is left alone.
		var before = Fs.current, memory = new MemoryWorkspace();
		Fs.current = memory;
		try {
			rayde.settings.Store.save("/project", "workspace-check", {a: 1});
			check(memory.exists("/project/.rayde/settings.json"), "settings are written through the current workspace");
			check(rayde.settings.Store.section("/project", "workspace-check").a == 1, "and read back through it");
		} catch (e:Dynamic) {
			Fs.current = before;
			throw e;
		}
		Fs.current = before;
		check(!sys.FileSystem.exists("/project/.rayde/settings.json"), "the local disk was not touched");
		Sys.println("Workspace: the local and in-memory providers answer alike");
	}

	/** Mounts send each path to its own workspace, and the page host assembles them. */
	static function routing():Void {
		var home = new MemoryWorkspace(), work = new MemoryWorkspace(), routed = new RoutedWorkspace(home);
		routed.mount("/work", work);
		routed.saveContent("/work/a.txt", "work");
		routed.saveContent("/home/b.txt", "home");
		check(work.exists("/work/a.txt") && !home.exists("/work/a.txt") && home.exists("/home/b.txt") && !work.exists("/home/b.txt"), "a path goes to the workspace mounted at its prefix");
		check(routed.exists("/work") && routed.isDirectory("/work") && routed.readDirectory("/").indexOf("work") >= 0, "a mount point is a directory of its parent");
		check(fails(() -> routed.rename("/work/a.txt", "/home/a.txt")) && work.exists("/work/a.txt"), "a rename does not cross workspaces");
		routed.copy("/work/a.txt", "/home/a.txt");
		check(home.getContent("/home/a.txt") == "work", "a copy does");
		conform(routed, "/work/conform", "routed workspace");
		conform(routed, "/home/conform", "routed fallback");

		var seen:Array<String> = [], memory = new MemoryWorkspace();
		memory.onChange = (path, kind) -> seen.push(kind + " " + path);
		memory.saveContent("/x/y.txt", "1");
		memory.rename("/x/y.txt", "/x/z.txt");
		memory.deleteFile("/x/z.txt");
		check(seen.join(",") == "mkdir /x,write /x/y.txt,delete /x/y.txt,rename /x/z.txt,delete /x/z.txt", 'changes are reported: $seen');
		var copy = new MemoryWorkspace();
		memory.saveContent("/keep/k.txt", "k");
		copy.load(memory.entries());
		check(copy.getContent("/keep/k.txt") == "k", "entries load into another workspace");

		#if rayde_page
		var before = Fs.current, beforeLauncher = Procs.current;
		var empty = PageHost.install(null,[{path:"/work/src/stale.hx",directory:false,bytes:Bytes.ofString("stale") }],false);
		check(empty == null && !Fs.exists("/work") && Fs.exists("/home/web/.rayde/themes"), "an anonymous page opens Welcome and ignores stale local workspace files");
		var entry = PageHost.install();
		check(entry == "/work/build.hxml" && Fs.exists(entry) && Fs.exists("/work/src/Main.hx"), "a page with no session opens a sample project");
		check(Fs.exists("/rayde/themes") && Fs.exists("/rayde/extensions/git/git.rayext.in") && !Fs.exists("/rayde/extensions/git/natives"), "built-in themes and extensions are embedded, natives are not");
		var ids = [for (entry in rayde.settings.Extensions.list("", rayde.settings.Extensions.builtins(), "")) entry.id];
		check(ids.indexOf("markdown") >= 0 && ids.indexOf("rayzor") >= 0, 'RayDE finds the embedded extensions: $ids');
		var none = Procs.start("true", []);
		check(none.exitCode() == 127 && none.stderr.readAll().toString().indexOf("session") >= 0, "a program started in a page with no session has ended, unsuccessfully, saying why");
		var partial = [{path:"/work/.rayde/settings.json", directory:false, bytes:Bytes.ofString("{}") }];
		entry = PageHost.install(null, partial);
		check(entry == "/work/build.hxml" && Fs.exists(entry) && Fs.exists("/work/src/Main.hx"), "saved settings with implicit parents do not suppress sample initialization");
		var edited = "class Main { static function main() { trace('kept λ'); } }\n", build = "-cp src\n-main Main\n--interp\n-D kept\n";
		partial.push({path:"/work/src/Main.hx", directory:false, bytes:Bytes.ofString(edited)});
		partial.push({path:"/work/build.hxml", directory:false, bytes:Bytes.ofString(build)});
		partial.push({path:"/work/src/notes.txt", directory:false, bytes:Bytes.ofString("keep this file")});
		PageHost.install(null, partial);
		check(Fs.getContent("/work/src/Main.hx") == edited && Fs.getContent("/work/build.hxml") == build, "repair preserves saved source and build edits");
		var saved = [for (file in PageHost.storage.entries()) if (StringTools.startsWith(file.path, "/work")) file];
		PageHost.install(null, saved);
		check(Fs.getContent("/work/src/Main.hx") == edited && Fs.getContent("/work/src/notes.txt") == "keep this file", "an initialized sample restores its saved files");
		Fs.rename("/work/src/Main.hx", "/work/src/Renamed.hx"); Fs.deleteFile("/work/build.hxml");
		saved = [for (file in PageHost.storage.entries()) if (StringTools.startsWith(file.path, "/work")) file];
		entry = PageHost.install(null, saved);
		check(entry == "/work" && !Fs.exists("/work/build.hxml") && !Fs.exists("/work/src/Main.hx") && Fs.getContent("/work/src/Renamed.hx") == edited,
			"deleted or renamed sample files stay absent and the folder remains openable");
		check(rayde.project.ProjectFile.read(entry).kind == "folder", "a sample without its build file opens as a folder workspace");
		Fs.current = before;
		Procs.current = beforeLauncher;
		#end
	}

	/** The session provider, against the real session server when it is built. */
	static function againstSession():Void {
		var binary = Sys.getCwd() + "native/session/target/debug/rayde-session";
		if (!sys.FileSystem.exists(binary)) { Sys.println("Workspace: skipped the session provider, native/session is not built"); return; }
		var root = sys.FileSystem.fullPath(Sys.getCwd() + "bin") + "/session-checks-" + Std.random(0x3fffffff), port = 20000 + Std.random(20000);
		sys.FileSystem.createDirectory(root);
		var raw = port + 1;
		var server = new sys.io.Process(binary, ["--root", root, "--port", Std.string(port), "--raw-port", Std.string(raw), "--token", "t", "--exec"]);
		try {
			var client:SessionClient = null;
			for (_ in 0...100) {
				try { client = SessionClient.connect("127.0.0.1", port, "t"); break; } catch (_:Dynamic) Sys.sleep(.05);
			}
			check(client != null, "the session server accepts a connection");
			var real = sys.FileSystem.fullPath(root);
			check(client.root == real, 'the session reports its root: ${client.root} vs $real');
			conform(new SessionWorkspace(client), client.root, "session workspace");
			#if rayde_page
			var beforeFiles = Fs.current, beforePrograms = Procs.current;
			try {
				var remote = new SessionWorkspace(client);
				remote.saveContent(client.root + "/remote.txt", "session workspace");
				var entry = PageHost.install(client, [{path:"/home/web/.rayde/settings.json", directory:false, bytes:Bytes.ofString("{}") }]);
				check(entry == client.root && Fs.getContent(client.root + "/remote.txt") == "session workspace" && !PageHost.storage.exists("/work"), "a remote page mounts its session without creating the local sample");
				remote.deleteFile(client.root + "/remote.txt");
			} catch (error:Dynamic) { Fs.current = beforeFiles; Procs.current = beforePrograms; throw error; }
			Fs.current = beforeFiles; Procs.current = beforePrograms;
			#end
			check(fails(() -> new SessionWorkspace(client).getContent("/elsewhere/file")), "a path outside the session's workspace fails");
			conformLauncher(new SessionLauncher(client), "session launcher");
			// The same session over frames on a byte stream, which is how a page reaches it.
			var stream:SessionClient = null;
			for (_ in 0...100) {
				try { stream = SessionClient.connectFramed("127.0.0.1", raw, "t"); break; } catch (_:Dynamic) Sys.sleep(.05);
			}
			check(stream != null && stream.root == client.root, "a framed connection reaches the same session");
			conform(new SessionWorkspace(stream), stream.root, "framed session workspace");
			conformLauncher(new SessionLauncher(stream), "framed session launcher");
			stream.close();
			client.close();
		} catch (e:Dynamic) {
			server.kill();
			server.close();
			throw e;
		}
		server.kill();
		server.close();
	}

	/** RayDE's own calls start programs through `Procs`, so a launcher elsewhere is used by all of them. */
	static function runThroughProcs():Void {
		var before = Procs.current, asked:Array<String> = [];
		Procs.current = new CannedLauncher((command, args) -> {
			asked.push(command + " " + args.join(" "));
			return {code: 0, out: '{"dir":"/w","name":"demo","entry":{"language":"haxe","module":"Main"},"languages":["haxe"],"haxe":{"cwd":"/w","args":["-cp","src"]},"problems":[]}', err: ""};
		});
		var had = Sys.getEnv("CARIBOU");
		Sys.putEnv("CARIBOU", "/remote/caribou");
		try {
			var info = rayde.project.CaribouProject.resolve("/w/demo.cbproj");
			check(info.name == "demo" && asked.length == 1 && asked[0] == "/remote/caribou project /w/demo.cbproj --json", 'Caribou is asked through the launcher: $asked');
		} catch (e:Dynamic) {
			Procs.current = before;
			throw e;
		}
		Procs.current = before;
		Sys.putEnv("CARIBOU", had == null ? "" : had);
	}

	public static function main():Void run();
}

/** A launcher that answers each start with what a function says, with nothing run. */
private class CannedLauncher implements Launcher {
	final answer:(String, Array<String>) -> {code:Int, out:String, err:String};

	public function new(answer:(String, Array<String>) -> {code:Int, out:String, err:String}) this.answer = answer;

	public function start(command:String, args:Array<String>):Program {
		var result = answer(command, args);
		return new CannedProgram(result.code, result.out, result.err);
	}
}

private class CannedProgram implements Program {
	public var stdout(default, null):haxe.io.Input;
	public var stderr(default, null):haxe.io.Input;
	public var stdin(default, null):haxe.io.Output = new haxe.io.BytesOutput();
	final code:Int;

	public function new(code:Int, out:String, err:String) {
		this.code = code;
		stdout = new haxe.io.BytesInput(haxe.io.Bytes.ofString(out));
		stderr = new haxe.io.BytesInput(haxe.io.Bytes.ofString(err));
	}

	public function exitCode(block:Bool = true):Null<Int> return code;
	public function kill():Void {}
	public function close():Void {}
}
