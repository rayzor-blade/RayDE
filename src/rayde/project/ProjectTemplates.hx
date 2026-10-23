package rayde.project;

typedef ProjectTemplate = {
	id:String,
	name:String,
	category:String,
	description:String,
	target:String,
	requirements:String,
	command:String,
	docs:String
};

typedef ProjectScaffold = {entry:String, files:Map<String, String>};

/** Offline starters shared by the project dialog and the creation worker. */
class ProjectTemplates {
	public static final all:Array<ProjectTemplate> = [
		{id:"hxml", name:"Haxe Application", category:"Applications", description:"A clean start for tools and apps.", target:"Cross-platform", requirements:"Haxe · Ash for RayDE Run", command:"haxe -cp src --run Main", docs:"https://haxe.org/manual/introduction-hello-world.html"},
		{id:"rayzor", name:"Rayzor", category:"Applications", description:"Native code with the Rayzor runtime.", target:"Native", requirements:"Rayzor", command:"rayzor run", docs:"https://github.com/rayzor-blade/rayzor"},
		{id:"haxelib", name:"Haxelib Library", category:"Libraries", description:"A reusable, publishable Haxe package.", target:"Haxelib", requirements:"Haxe · Haxelib", command:"haxe -cp src --no-output Library", docs:"https://haxe.org/manual/haxelib-json.html"},
		{id:"javascript", name:"Web Application", category:"Applications", description:"Haxe to JavaScript, ready for a browser.", target:"HTML5", requirements:"Haxe · Web browser", command:"haxe build.hxml", docs:"https://haxe.org/manual/target-javascript-getting-started.html"},
		{id:"hashlink", name:"HashLink", category:"Applications", description:"A bytecode application for HashLink.", target:"Desktop", requirements:"Haxe · HashLink", command:"haxe build.hxml && hl bin/app.hl", docs:"https://haxe.org/manual/target-hl-getting-started.html"},
		{id:"heaps", name:"Heaps", category:"Games", description:"A 2D and 3D engine, starting on the web.", target:"HTML5", requirements:"Haxe · heaps (haxelib install heaps)", command:"haxe build.hxml", docs:"https://github.com/HeapsIO/heaps/wiki/Hello-World"},
		{id:"openfl", name:"OpenFL", category:"Games", description:"Interactive graphics with a display list.", target:"Web · Desktop · Mobile", requirements:"Haxe · openfl (haxelib install openfl)", command:"haxelib run lime test html5", docs:"https://www.openfl.org/learn/docs/getting-started/"},
		{id:"flixel", name:"HaxeFlixel", category:"Games", description:"A 2D game with a ready-to-use play state.", target:"Web · Desktop · Mobile", requirements:"Haxe · flixel (haxelib install flixel)", command:"haxelib run lime test html5", docs:"https://haxeflixel.com/documentation/hello-world/"},
		{id:"lime", name:"Lime", category:"Applications", description:"A lightweight multimedia application.", target:"Web · Desktop · Mobile", requirements:"Haxe · lime (haxelib install lime)", command:"haxelib run lime test html5", docs:"https://lime.openfl.org/docs/command-line-tools/create-new-project/"}
	];

	public static function get(id:String):ProjectTemplate {
		for (template in all) if (template.id == id) return template;
		throw "Unknown project template";
	}

	public static function matching(category:String):Array<ProjectTemplate>
		return category == "All" ? all : all.filter(template -> template.category == category);

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
			case "hashlink": files.set(entry, build + "-hl bin/app.hl\n");
			case "heaps":
				main = 'class Main extends hxd.App {\n\toverride function init() {\n\t\tvar label = new h2d.Text(hxd.res.DefaultFont.get(), s2d);\n\t\tlabel.text = "Hello from Heaps!";\n\t\tlabel.x = 24;\n\t\tlabel.y = 24;\n\t}\n\n\tstatic function main() {\n\t\tnew Main();\n\t}\n}\n';
				files.set(entry, build + "-lib heaps\n-js bin/app.js\n");
				files.set("index.html", html(name, '<canvas id="webgl" style="width:100%;height:100%"></canvas>'));
			case "openfl" | "flixel" | "lime":
				entry = "haxelib.json";
				var library = id == "flixel" ? "flixel" : id;
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
		return {entry:entry, files:files};
	}

	static function manifest(name:String, libraries:Array<String>, description:String):String {
		var dependencies:Dynamic = {};
		for (library in libraries) Reflect.setField(dependencies, library, "");
		return haxe.Json.stringify({name:name.toLowerCase(), version:"0.1.0", classPath:"src", license:"MIT", description:description, contributors:[], dependencies:dependencies}, null, "\t") + "\n";
	}

	static function html(name:String, body:String):String
		return '<!doctype html>\n<html lang="en">\n<head>\n\t<meta charset="utf-8">\n\t<meta name="viewport" content="width=device-width, initial-scale=1">\n\t<title>$name</title>\n</head>\n<body style="margin:0;height:100vh">\n\t$body\n\t<script src="bin/app.js"></script>\n</body>\n</html>\n';
}
