package rayde.project;

import haxe.io.Path;
import rayde.lang.Hxml;
import sys.FileSystem;
import sys.io.File;

/** Project entry metadata and compiler inputs, independent of views and editor buffers. */
class ProjectFile {
	public final file:String;
	public final root:String;
	public var name(default, null):String;
	public var kind(default, null):String;
	public var runtime(default, null) = "ash";
	public var hxml(default, null):Null<String>;
	public var main(default, null):Null<String>;
	public var args(default, null):Array<String> = [];
	public var runnable(default, null) = true;

	function new(file:String, folder = false) { this.file = file; root = folder ? file : Path.directory(file); name = Path.withoutDirectory(root); if (name == "") name = root; }

	public static function supported(file:String):Bool {
		var name = Path.withoutDirectory(file).toLowerCase();
		return StringTools.endsWith(name, ".hxml") || name == "haxelib.json" || name == "rayzor.toml";
	}

	public static function read(file:String):ProjectFile {
		file = FileSystem.fullPath(file);
		if (FileSystem.isDirectory(file)) {
			var workspace = new ProjectFile(file, true);
			workspace.kind = "folder"; workspace.runtime = ""; workspace.runnable = false;
			return workspace;
		}
		if (!supported(file)) throw "Choose a folder, .hxml, haxelib.json or rayzor.toml project file";
		var project = new ProjectFile(file), name = Path.withoutDirectory(file).toLowerCase();
		if (StringTools.endsWith(name, ".hxml")) {
			project.kind = "hxml"; project.hxml = file; project.args = Hxml.read(file);
			return project;
		}
		if (FileSystem.stat(file).size > 2 * 1024 * 1024) throw "Project manifest exceeds 2 MiB";
		var source = File.getContent(file);
		if (name == "haxelib.json") {
			var data:Dynamic = haxe.Json.parse(source);
			project.kind = "haxelib"; project.runnable = false;
			project.name = requiredString(data, "name");
			var sourcePath = optionalString(data, "classPath", true);
			project.args = ["-cp", sourcePath == null || sourcePath == "" ? "." : sourcePath];
			if (data.dependencies != null) for (library in Reflect.fields(data.dependencies)) {
				var version = requiredString(data.dependencies, library, true);
				project.args = project.args.concat(["-L", library + (version == "" ? "" : ":" + version)]);
			}
			var extra = project.root + "/extraParams.hxml";
			if (FileSystem.exists(extra)) project.args = project.args.concat(Hxml.read(extra));
			return project;
		}
		var bytes = haxe.io.Bytes.ofString(source), data = unpack(tomlNative(bytes.getData(), bytes.length)).value;
		project.kind = "rayzor"; project.runtime = "rayzor";
		if (data.project == null && data.workspace == null) throw "rayzor.toml needs a [project] or [workspace] section";
		if (data.project != null) project.name = optionalString(data.project, "name") ?? project.name;
		var delegated = data.project == null ? null : optionalString(data.project, "hxml");
		if (delegated != null) {
			project.hxml = Path.isAbsolute(delegated) ? delegated : Path.join([project.root, delegated]);
			project.args = ["--cwd", Path.directory(project.hxml)].concat(Hxml.read(project.hxml));
		} else {
			var paths:Dynamic = data.build == null ? null : Reflect.field(data.build, "class-paths");
			if (paths == null) paths = [FileSystem.exists(project.root + "/src") ? "src" : "."];
			if (!Std.isOfType(paths, Array)) throw "build.class-paths must be an array of strings";
			for (path in (paths:Array<Dynamic>)) {
				if (!Std.isOfType(path, String) || path == "") throw "build.class-paths must contain nonempty strings";
				project.args = project.args.concat(["-cp", path]);
			}
			if (data.build != null && data.build.defines != null) for (define in Reflect.fields(data.build.defines)) {
				var value:Dynamic = Reflect.field(data.build.defines, define);
				project.args = project.args.concat(["-D", define + (value == true ? "" : "=" + Std.string(value))]);
			}
		}
		var entry = data.project == null ? null : optionalString(data.project, "entry");
		project.runnable = data.project != null && (entry != null || delegated != null);
		if (entry != null) {
			project.main = Path.normalize(Path.isAbsolute(entry) ? entry : Path.join([project.root, entry]));
			var module:Null<String> = null;
			for (i in 0...project.args.length - 1) if (project.args[i] == "-cp") {
				var cp = project.args[i + 1];
				cp = Path.addTrailingSlash(Path.normalize(Path.isAbsolute(cp) ? cp : Path.join([project.root, cp])));
				if (StringTools.startsWith(project.main, cp)) {
					module = Path.withoutExtension(project.main.substr(cp.length)).split("/").join(".");
					break;
				}
			}
			if (module == null) { project.args = project.args.concat(["-cp", Path.directory(project.main)]); module = Path.withoutExtension(Path.withoutDirectory(project.main)); }
			project.args = project.args.concat(["-main", module]);
		}
		return project;
	}

	static function optionalString(object:Dynamic, key:String, empty = false):Null<String> {
		var value:Dynamic = object == null ? null : Reflect.field(object, key);
		if (value == null) return null;
		if (!Std.isOfType(value, String) || !empty && value == "") throw key + " must be a nonempty string";
		return value;
	}
	static function requiredString(object:Dynamic, key:String, empty = false):String {
		var value:Dynamic = object == null ? null : Reflect.field(object, key);
		if (!Std.isOfType(value, String) || !empty && value == "") throw key + " must be a string";
		return value;
	}
	static function unpack(bytes:hl.Bytes):Dynamic {
		if (bytes == null) throw "Project file operation failed";
		var data:Dynamic = haxe.Json.parse(bytes.sub(4, bytes.getI32(0)).toBytes(bytes.getI32(0)).toString());
		if (data.error != null) throw Std.string(data.error);
		return data;
	}
	public static function validName(name:String):Bool return name != null && ~/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.match(name);

	/** Creates a fresh directory exclusively; existing projects are never overwritten. */
	public static function create(parent:String, name:String, kind:String):String {
		if (!validName(name)) throw "Use a project name starting with a letter, followed by letters, numbers, hyphens or underscores (up to 64 characters)";
		if (["hxml", "haxelib", "rayzor"].indexOf(kind) < 0) throw "Unknown project type";
		parent = FileSystem.fullPath(parent);
		if (!FileSystem.isDirectory(parent)) throw "Choose a parent folder";
		var root = Path.join([parent, name]), bytes = haxe.io.Bytes.ofString(root);
		unpack(directoryNative(bytes.getData(), bytes.length));
		var written:Array<String> = [];
		function write(path:String, text:String):Void { File.saveContent(root + "/" + path, text); written.push(root + "/" + path); }
		try {
			FileSystem.createDirectory(root + "/src");
			write(".gitignore", ".rayde/\n.rayzor/\nbin/\nbuild/\n");
			var entry = kind == "hxml" ? "build.hxml" : kind == "haxelib" ? "haxelib.json" : "rayzor.toml";
			if (kind == "haxelib") {
				write(entry, haxe.Json.stringify({name:name.toLowerCase(), version:"0.1.0", classPath:"src", license:"MIT", description:"", contributors:[], dependencies:{}}, null, "\t") + "\n");
				write("src/Library.hx", "class Library {\n\tpublic static function hello():String {\n\t\treturn \"Hello!\";\n\t}\n}\n");
			} else {
				write("src/Main.hx", "class Main {\n\tstatic function main() {\n\t\ttrace(\"Hello, world!\");\n\t}\n}\n");
				write(entry, kind == "hxml" ? "-cp src\n-main Main\n" : '[project]\nname = "$name"\nversion = "0.1.0"\nentry = "src/Main.hx"\n\n[build]\nclass-paths = ["src"]\nopt-level = 2\npreset = "application"\noutput = "build/$name"\n\n[cache]\nenabled = true\n');
			}
			return root + "/" + entry;
		} catch (error:Dynamic) {
			for (file in written) try FileSystem.deleteFile(file) catch (_:Dynamic) {}
			try FileSystem.deleteDirectory(root + "/src") catch (_:Dynamic) {}
			try FileSystem.deleteDirectory(root) catch (_:Dynamic) {}
			throw error;
		}
	}

	@:hlNative("rayscript", "project_toml") static function tomlNative(data:hl.Bytes, length:Int):hl.Bytes return null;
	@:hlNative("rayscript", "project_directory") static function directoryNative(data:hl.Bytes, length:Int):hl.Bytes return null;
}
