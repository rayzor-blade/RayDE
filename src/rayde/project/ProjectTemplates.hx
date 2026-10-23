package rayde.project;

typedef ProjectTemplate = {
	id:String,
	name:String,
	category:String,
	description:String,
	target:String,
	requirements:String,
	command:String,
	docs:String,
	?icon:String,
	?iconPath:String,
	?owner:String,
	?scaffold:ProjectScaffold
};

typedef ProjectScaffold = {entry:String, files:Map<String, String>};

/** Offline starters shared by the project dialog and the creation worker. */
class ProjectTemplates {
	public static final all:Array<ProjectTemplate> = [
		{id:"hxml", name:"Haxe Application", category:"Applications", description:"The cross-platform toolkit.", target:"Cross-platform", requirements:"Haxe · Ash or HashLink for RayDE Run", command:"haxe -cp src --run Main", docs:"https://haxe.org/manual/introduction-hello-world.html"},
		{id:"ash", name:"Ash", category:"Applications", description:"A faster runtime for HashLink bytecode.", target:"Cross-platform", requirements:"Haxe · Ash", command:"haxe build.hxml && ash --preset application bin/app.hl", docs:"https://github.com/rayzor-blade/ash"},
		{id:"ashui", name:"Ashui", category:"Applications", description:"Native, reactive UI for Haxe.", target:"Cross-platform", requirements:"Haxe · Ash · ashui · ashui-components", command:"haxe build.hxml && ash --preset application bin/app.hl", docs:"https://github.com/rayzor-blade/ashui"},
		{id:"rayzor", name:"Rayzor", category:"Applications", description:"Instant Haxe. Native performance.", target:"Cross-platform", requirements:"Rayzor", command:"rayzor run", docs:"https://github.com/rayzor-blade/rayzor"},
		{id:"haxelib", name:"Haxelib Library", category:"Libraries", description:"A reusable, publishable Haxe package.", target:"Cross-platform", requirements:"Haxe · Haxelib", command:"haxe -cp src --no-output Library", docs:"https://haxe.org/manual/haxelib-json.html"},
		{id:"javascript", name:"Web Application", category:"Applications", description:"Haxe to JavaScript, ready for a browser.", target:"Web", requirements:"Haxe · Web browser", command:"haxe build.hxml", docs:"https://haxe.org/manual/target-javascript-getting-started.html"},
		{id:"hashlink", name:"HashLink", category:"Applications", description:"A high performance virtual machine for Haxe.", target:"Cross-platform", requirements:"Haxe · HashLink (Ash on Apple Silicon)", command:"haxe build.hxml", docs:"https://haxe.org/manual/target-hl-getting-started.html"},
		{id:"heaps", name:"Heaps", category:"Games", description:"Cross platform graphics for high performance games.", target:"Cross-platform", requirements:"Haxe · heaps (haxelib install heaps)", command:"haxe build.hxml", docs:"https://github.com/HeapsIO/heaps/wiki/Hello-World"},
		{id:"openfl", name:"OpenFL", category:"Applications", description:"Creative expression for desktop, mobile, web and console platforms.", target:"Cross-platform", requirements:"Haxe · openfl (haxelib install openfl)", command:"haxelib run lime test html5", docs:"https://www.openfl.org/learn/docs/getting-started/"},
		{id:"flixel", name:"HaxeFlixel", category:"Games", description:"Create cross-platform games easier and free.", target:"Cross-platform", requirements:"Haxe · flixel (haxelib install flixel)", command:"haxelib run lime test html5", docs:"https://haxeflixel.com/documentation/hello-world/"},
		{id:"lime", name:"Lime", category:"Applications", description:"Mobile, Desktop, Web and More.", target:"Cross-platform", requirements:"Haxe · lime (haxelib install lime)", command:"haxelib run lime test html5", docs:"https://lime.openfl.org/docs/command-line-tools/create-new-project/"}
	];

	public static function get(id:String):ProjectTemplate {
		for (template in all) if (template.id == id) return template;
		throw "Unknown project template";
	}

	public static function matching(category:String, ?catalog:Array<ProjectTemplate>):Array<ProjectTemplate> {
		var templates = catalog ?? all;
		return category == "All" ? templates : templates.filter(template -> template.category == category);
	}

	public static function scaffold(id:String, name:String):ProjectScaffold {
		var template = get(id), files:Map<String, String> = [".gitignore" => ".rayde/\n.rayzor/\nbin/\nbuild/\nExport/\n"];
		var entry = "build.hxml";
		var main = 'class Main {\n\tstatic function main() {\n\t\ttrace("Hello, world!");\n\t}\n}\n';
		var build = "-cp src\n-main Main\n";
		switch id {
			case "hxml": files.set(entry, build);
			case "rayzor":
				entry = "rayzor.toml";
				files.set(entry, '[project]\nname = "$name"\nversion = "0.1.0"\nentry = "src/Main.hx"\n\n[build]\nclass-paths = ["src"]\nopt-level = 2\npreset = "application"\noutput = "build/$name"\n\n[cache]\nenabled = true\n');
			case "haxelib":
				entry = "haxelib.json";
				files.set(entry, manifest(name, [], "A Haxe library"));
				files.set("src/Library.hx", 'class Library {\n\tpublic static function hello():String {\n\t\treturn "Hello!";\n\t}\n}\n');
			case "javascript":
				main = 'class Main {\n\tstatic function main() {\n\t\tjs.Browser.document.getElementById("app").textContent = "Hello from Haxe!";\n\t}\n}\n';
				files.set(entry, build + "-js bin/app.js\n");
				files.set("index.html", html(name, '<main id="app"></main>'));
			case "hashlink" | "ash": files.set(entry, build + "-hl bin/app.hl\n");
			case "ashui":
				main = 'import ashui.app.WindowedApp;\nimport ashui.components.Button;\nimport ashui.reactive.Reactive;\n\nclass Main {\n\tstatic function main() {\n\t\tWindowedApp.run({title: "$name", width: 800, height: 600}, () -> {\n\t\t\tvar count = signal(0);\n\t\t\treturn <div widthPercent={1} heightPercent={1} class="flex flex-col items-center justify-center gap-4 p-6 bg-background text-text-primary">\n\t\t\t\t<text class="text-2xl font-semibold">Hello, Ashui!</text>\n\t\t\t\t<button onClick={_ -> count.set(count.get() + 1)}>Clicked $${count.get()} times</button>\n\t\t\t</div>;\n\t\t});\n\t}\n}\n';
				files.set(entry, "-lib ashui\n-lib ashui-components\n--macro ashui.core.render.UiFramework.register()\n--macro ashui.ui.Markup.enable()\n" + build + "-hl bin/app.hl\n");
			case "heaps":
				main = 'class Main extends hxd.App {\n\toverride function init() {\n\t\tvar label = new h2d.Text(hxd.res.DefaultFont.get(), s2d);\n\t\tlabel.text = "Hello from Heaps!";\n\t\tlabel.x = 24;\n\t\tlabel.y = 24;\n\t}\n\n\tstatic function main() {\n\t\tnew Main();\n\t}\n}\n';
				files.set(entry, build + "-lib heaps\n-js bin/app.js\n");
				files.set("native.hxml", build + "-lib heaps\n-lib format\n-lib hlsdl\n-hl bin/app.hl\n");
				files.set("index.html", html(name, '<canvas id="webgl" style="width:100%;height:100%"></canvas>'));
			case "openfl" | "flixel" | "lime":
				entry = "haxelib.json";
				var library = id;
				files.set(entry, manifest(name, [library], template.description));
				files.set("project.xml", '<?xml version="1.0" encoding="utf-8"?>\n<project>\n\t<meta title="$name" package="app.${name.toLowerCase().split("-").join("_")}" version="0.1.0" />\n\t<app main="Main" file="$name" path="Export" />\n\t<source path="src" />\n\t<haxelib name="$library" />\n\t<window width="960" height="640" />\n</project>\n');
				main = id == "lime"
					? 'class Main extends lime.app.Application {\n\tpublic function new() {\n\t\tsuper();\n\t}\n}\n'
					: id == "flixel"
					? 'class Main extends openfl.display.Sprite {\n\tpublic function new() {\n\t\tsuper();\n\t\taddChild(new flixel.FlxGame(960, 640, PlayState.new));\n\t}\n}\n'
					: 'class Main extends openfl.display.Sprite {\n\tpublic function new() {\n\t\tsuper();\n\t\tvar label = new openfl.text.TextField();\n\t\tlabel.text = "Hello from OpenFL!";\n\t\tlabel.width = 400;\n\t\tlabel.x = 24;\n\t\tlabel.y = 24;\n\t\taddChild(label);\n\t}\n}\n';
				if (id == "flixel") files.set("src/PlayState.hx", 'class PlayState extends flixel.FlxState {\n\toverride public function create():Void {\n\t\tsuper.create();\n\t\tadd(new flixel.text.FlxText(24, 24, 0, "Hello from HaxeFlixel!", 24));\n\t}\n}\n');
		}
		if (id != "haxelib") files.set("src/Main.hx", main);
		files.set("README.md", '# $name\n\n${template.description}\n\n## Requirements\n\n${template.requirements}\n\n## Get started\n\nRun in this project\'s terminal:\n\n```sh\n${template.command}\n```\n' + (id == "javascript" || id == "heaps" ? "\nThen open `index.html` in your browser.\n" : "") + '\n[Documentation](${template.docs})\n');
		if (id == "ashui") files.set("README.md", files.get("README.md") + "\nInstall the UI libraries with `haxelib install ashui` and `haxelib install ashui-components`. Their native libraries are staged beside the compiled bytecode automatically.\n");
		if (id == "ash" || id == "ashui") files.set("README.md", files.get("README.md") + "\nTo build a native executable, run `ash --build bin/app bin/app.hl`.\n");
		if (id == "heaps") files.set("README.md", files.get("README.md") + "\n## Native build\n\nInstall `format` and `hlsdl` with Haxelib, then run `haxe native.hxml` and `hl bin/app.hl`.\n");
		if (id == "ash" || id == "ashui") ProjectRunner.configure(files, "ash");
		if (id == "hashlink") {
			ProjectRunner.configure(files, "auto");
			files.set("README.md", files.get("README.md") + "\nRayDE uses Ash for HashLink bytecode on Apple Silicon, and `hl` on other platforms. Change the project's default in Settings > Run.\n");
		}
		return {entry:entry, files:files};
	}

	/** Checks extension-supplied files before creating any destination. */
	public static function validate(scaffold:ProjectScaffold):Void {
		if (scaffold == null || scaffold.files == null) throw "A starter needs project files";
		var seen = new Map<String, Bool>(), total = 0, count = 0;
		for (path => text in scaffold.files) {
			if (!relativePath(path)) throw 'Invalid starter file path: $path';
			var key = path.toLowerCase();
			if (seen.exists(key)) throw "Starter file paths must be unique on every platform";
			seen.set(key, true);
			if (text == null) throw "Starter files must be text";
			var size = haxe.io.Bytes.ofString(text).length;
			if (size > 1024 * 1024) throw "Starter files must be at most 1 MiB each";
			total += size;
			if (++count > 256 || total > 4 * 1024 * 1024) throw "Starter exceeds 256 files or 4 MiB of text";
		}
		if (count == 0) throw "A starter needs at least one file";
		for (key in seen.keys()) {
			var parts = key.split("/"); parts.pop();
			while (parts.length > 0) {
				if (seen.exists(parts.join("/"))) throw "A starter file cannot also be a folder";
				parts.pop();
			}
		}
		if (scaffold.entry != "" && (!relativePath(scaffold.entry) || !scaffold.files.exists(scaffold.entry) || !ProjectFile.supported(scaffold.entry)))
			throw "Starter entry must name an included .hxml, haxelib.json or rayzor.toml file, or be empty for a folder workspace";
	}

	public static function relativePath(path:String):Bool {
		if (path == null || path.length == 0 || path.length > 240 || haxe.io.Path.isAbsolute(path) || ~/[\\\x00-\x1f<>:"|?*]/.match(path)) return false;
		for (part in path.split("/")) if (part == "" || part == "." || part == ".." || StringTools.endsWith(part, ".") || StringTools.endsWith(part, " ")) return false;
		return true;
	}

	/** Placeholders apply to file contents; file paths remain literal relative paths. */
	public static function instantiate(scaffold:ProjectScaffold, name:String):ProjectScaffold {
		validate(scaffold);
		var files = [for (path => text in scaffold.files) path => StringTools.replace(text, "{{name}}", name)];
		var result = {entry:scaffold.entry, files:files};
		validate(result);
		return result;
	}

	static function manifest(name:String, libraries:Array<String>, description:String):String {
		var dependencies:Dynamic = {};
		for (library in libraries) Reflect.setField(dependencies, library, "");
		return haxe.Json.stringify({name:name.toLowerCase(), version:"0.1.0", classPath:"src", license:"MIT", description:description, contributors:[], dependencies:dependencies}, null, "\t") + "\n";
	}

	static function html(name:String, body:String):String
		return '<!doctype html>\n<html lang="en">\n<head>\n\t<meta charset="utf-8">\n\t<meta name="viewport" content="width=device-width, initial-scale=1">\n\t<title>$name</title>\n</head>\n<body style="margin:0;height:100vh">\n\t$body\n\t<script src="bin/app.js"></script>\n</body>\n</html>\n';
}
