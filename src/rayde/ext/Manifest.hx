package rayde.ext;

/**
 * An extension's config file, `<name>.rayext`: JSON that names the extension and says where its code is.
 * It is to an extension what a `.hxml` is to a Haxe project: RayDE opens it, and the folder it is in is the
 * project. Only `name` and `main` matter to the Studio so far; the rest is for when extensions are installed.
 *
 *     {
 *       "name": "Notes",
 *       "version": "0.1.0",
 *       "description": "A notes panel",
 *       "main": "ext/main.rays",
 *       "sources": ["ext"],
 *       "mocks": "ext/studio.mocks.json",
 *       "capabilities": ["workspace.read"]
 *     }
 *
 * `main` is the script that starts the extension (`main.rays` unless named). `sources` are the folders its
 * scripts are in, where `import a.b.C` looks for `a/b/C.rays` (the first one); by default the folder of
 * `main`. `mocks` is the file that answers the extension's remote calls while it is developed, by default
 * `studio.mocks.json` beside `main`. A path is relative to the config file.
 */
class Manifest {
	/** The file's extension, with its dot. */
	public static inline var EXTENSION = ".rayext";

	public final file:String;

	/** The folder the config file is in. */
	public final root:String;

	public final name:String;
	public final version:String;
	public final description:String;
	public final main:String;
	public final sources:Array<String>;
	public final mocks:String;
	public final capabilities:Array<String>;

	/** What is wrong with the file, as sentences; the fields above are filled in with their defaults where they were wrong or missing. */
	public final problems:Array<String> = [];

	function new(file:String, json:Dynamic) {
		this.file = file;
		root = haxe.io.Path.directory(file);
		var fallback = haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(file));
		name = text(json, "name", fallback);
		version = text(json, "version", "");
		description = text(json, "description", "");
		main = text(json, "main", "main.rays");
		var folder = haxe.io.Path.directory(main);
		var listed = strings(json, "sources");
		sources = listed.length > 0 ? listed : [folder == "" ? "." : folder];
		mocks = text(json, "mocks", haxe.io.Path.join([folder, "studio.mocks.json"]));
		capabilities = strings(json, "capabilities");
		if (!sys.FileSystem.exists(mainPath()))
			problems.push('The main script ${main} is not there.');
	}

	/** Reads the config file; one that cannot be read gives an extension with the defaults and the reason in `problems`. */
	public static function read(file:String):Manifest {
		var json:Dynamic = {};
		var why:Null<String> = null;
		try
			json = haxe.Json.parse(sys.io.File.getContent(file))
		catch (e:Dynamic)
			why = 'The file is not JSON: $e';
		if (why == null && (json == null || Std.isOfType(json, Array) || !Reflect.isObject(json))) {
			why = "The file should hold one JSON object.";
			json = {};
		}
		var m = new Manifest(sys.FileSystem.fullPath(file), why == null ? json : {});
		if (why != null)
			m.problems.unshift(why);
		return m;
	}

	public static function isManifest(path:String):Bool
		return StringTools.endsWith(path, EXTENSION);

	function text(json:Dynamic, field:String, fallback:String):String {
		var v:Dynamic = Reflect.field(json, field);
		if (v == null)
			return fallback;
		if (!Std.isOfType(v, String)) {
			problems.push('"$field" should be text.');
			return fallback;
		}
		return v == "" ? fallback : v;
	}

	function strings(json:Dynamic, field:String):Array<String> {
		var v:Dynamic = Reflect.field(json, field);
		if (v == null)
			return [];
		if (!Std.isOfType(v, Array) || !Lambda.foreach((v : Array<Dynamic>), x -> Std.isOfType(x, String))) {
			problems.push('"$field" should be a list of text.');
			return [];
		}
		return v;
	}

	function absolute(path:String):String
		return haxe.io.Path.normalize(haxe.io.Path.isAbsolute(path) ? path : haxe.io.Path.join([root, path]));

	/** The main script, in full. */
	public function mainPath():String
		return absolute(main);

	/** Where the mocked answers are, in full. */
	public function mocksPath():String
		return absolute(mocks);

	/** The source folders that exist: the label as written, and the folder in full. */
	public function sourceDirs():Array<{label:String, dir:String}> {
		var out = [];
		for (s in sources) {
			var dir = absolute(s);
			if (sys.FileSystem.exists(dir) && sys.FileSystem.isDirectory(dir))
				out.push({label: s, dir: dir});
		}
		return out;
	}

	/** The folder `import a.b.C` looks in: the first source folder, or the project's own. */
	public function importRoot():String {
		var dirs = sourceDirs();
		return dirs.length > 0 ? dirs[0].dir : root;
	}
}
