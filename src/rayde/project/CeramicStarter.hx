package rayde.project;

/** Ceramic owns its build metadata and local libraries; RayDE opens the source folder. */
class CeramicStarter {
	public static function files(name:String):Map<String, String> return [
		"src/import.hx" => "#if !macro\nimport ceramic.Shortcuts.*;\n#end\n",
		"ceramic.yml" => 'app:\n    package: "app.project_${name.toLowerCase().split("-").join("_")}"\n    name: "$name"\n    displayName: "$name"\n    author: Your Name\n    version: \'0.1.0\'\n',
		"src/Project.hx" => 'import ceramic.Color;\nimport ceramic.Entity;\nimport ceramic.InitSettings;\n\nclass Project extends Entity {\n\tfunction new(settings:InitSettings) {\n\t\tsuper();\n\t\tsettings.background = Color.BLACK;\n\t\tsettings.targetWidth = 960;\n\t\tsettings.targetHeight = 640;\n\t\tsettings.scaling = FIT;\n\t\tsettings.resizable = true;\n\t\tapp.onceReady(this, () -> app.scenes.main = new MainScene());\n\t}\n}\n',
		"src/MainScene.hx" => 'import ceramic.Color;\nimport ceramic.Quad;\nimport ceramic.Scene;\n\nclass MainScene extends Scene {\n\tvar square:Quad;\n\n\toverride function create() {\n\t\tsquare = new Quad();\n\t\tsquare.size(120, 120);\n\t\tsquare.color = Color.fromRGB(255, 153, 0);\n\t\tsquare.anchor(0.5, 0.5);\n\t\tadd(square);\n\t\tplaceSquare();\n\t}\n\n\toverride function resize(width:Float, height:Float) {\n\t\tif (square != null) placeSquare();\n\t}\n\n\tfunction placeSquare() square.pos(width * 0.5, height * 0.5);\n}\n',
		"assets/.gitkeep" => "",
		".gitignore" => ".rayde/\n.haxelib/\nbin/\ngen/\nout/\nproject/\ncompletion.hxml\n",
		"README.md" => '# $name\n\nA [Ceramic](https://ceramic-engine.com/) app with a centered square, ready for 2D apps and games.\n\n## Get started\n\nInstall Ceramic using its [installation guide](https://ceramic-engine.com/guides/install-ceramic/), then run from this folder:\n\n```sh\nceramic clay run web --setup --assets\n```\n\nCeramic sets up the selected backend, local libraries and generated Haxe files. RayDE opens this project as a folder workspace; `ceramic.yml` is the build configuration. Edit `src/Project.hx` for app settings and `src/MainScene.hx` for the scene. Add images and other assets under `assets/`.\n\n## Native platforms\n\nCeramic supports web, desktop and mobile targets, with additional backend support for Unity. Install the relevant tools from the [platform setup guide](https://ceramic-engine.com/guides/platform-setup/), then replace `web` with the desired target (for example `mac`, `windows` or `linux`).\n\n[Project configuration reference](https://ceramic-engine.com/guides/ceramic-yml-reference/)\n'
	];
}
