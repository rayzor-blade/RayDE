import haxe.io.Bytes;
import rayde.workspace.Fs;
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
		check(ws.readDirectory(at("src")).join(",") == "B.hx,pkg", '$label: directory entries are names, in name order: ${ws.readDirectory(at("src"))}');
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

	public static function run():Void {
		var local = Sys.getCwd() + "bin/workspace-checks-" + Std.random(0x3fffffff);
		sys.FileSystem.createDirectory(local);
		conform(new LocalWorkspace(), local, "local");
		sys.FileSystem.deleteDirectory(local);
		conform(new MemoryWorkspace(), "/work", "memory");

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

	public static function main():Void run();
}
