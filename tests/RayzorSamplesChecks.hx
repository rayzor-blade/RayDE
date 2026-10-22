import haxe.io.Path;
import rayde.build.RayzorFile;
import rayde.project.ProjectFile;
import sys.FileSystem;
import sys.io.File;

/** Checks real Rayzor manifests read-only; form edits use copies under bin. */
class RayzorSamplesChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }

	public static function main():Void {
		var repo = FileSystem.fullPath(Sys.args().length == 0 ? "../rayzor" : Sys.args()[0]);
		var manifests:Array<String> = [], failures:Array<String> = [];
		function visit(dir:String):Void {
			for (name in FileSystem.readDirectory(dir)) {
				if (name.charAt(0) == "." || ["target", "node_modules"].indexOf(name) >= 0) continue;
				var path = Path.join([dir, name]);
				if (FileSystem.isDirectory(path)) visit(path); else if (name == "rayzor.toml") manifests.push(path);
			}
		}
		visit(repo); manifests.sort(Reflect.compare);
		check(manifests.length > 0, "No Rayzor sample manifests found");
		for (path in manifests) try {
			var before = File.getContent(path), project = ProjectFile.read(path), manifest = new RayzorFile(path);
			check(project.root == Path.directory(path) && project.kind == "rayzor", "Lost manifest root or project kind");
			var entry = manifest.text(["project", "entry"]), hxml = manifest.text(["project", "hxml"]);
			check(project.runnable == (!manifest.workspace() && entry != ""), "Wrong Run availability for library/workspace/application");
			if (entry != "" && hxml == "") {
				var full = Path.normalize(Path.isAbsolute(entry) ? entry : Path.join([project.root, entry]));
				var expected:Null<String> = null;
				for (cp in manifest.strings(["build", "class-paths"])) {
					var dir = Path.addTrailingSlash(Path.normalize(Path.isAbsolute(cp) ? cp : Path.join([project.root, cp])));
					if (StringTools.startsWith(full, dir)) { expected = Path.withoutExtension(full.substr(dir.length)).split("/").join("."); break; }
				}
				if (expected != null) {
					var index = project.args.indexOf("-main");
					check(index >= 0 && project.args[index + 1] == expected, 'Entry module must use the first matching class path: expected $expected, got ${index < 0 ? "none" : project.args[index + 1]}');
				}
			}
			check(File.getContent(path) == before, "Checking a sample modified its manifest");
		} catch (e:Dynamic) failures.push(path.substr(repo.length + 1) + ": " + Std.string(e));
		if (failures.length > 0) throw failures.join("\n");
		Sys.println('Rayzor samples: ${manifests.length} real manifests parsed, entry/class-path precedence checked, libraries and workspaces omit Run');
	}
}
