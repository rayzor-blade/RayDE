package rayde.ui;

/** The language a file is shown as in the status bar, or null for what is not text a language applies to. */
class LanguageNames {
	public static function id(file:String):String {
		return switch of(file) {
			case "C++": "cpp"; case "C#": "csharp"; case "F#": "fsharp";
			case "JavaScript React": "javascriptreact"; case "TypeScript React": "typescriptreact";
			case "Shell Script": "shellscript"; case "Plain Text" | null: "plaintext";
			case name: name.toLowerCase();
		};
	}
	static final BY_NAME = ["dockerfile" => "Dockerfile", "containerfile" => "Dockerfile", "makefile" => "Makefile", "justfile" => "Just", "cmakelists.txt" => "CMake"];
	static final BY_EXTENSION:Map<String, String> = {
		var names = new Map<String, String>();
		function add(language:String, extensions:Array<String>) for (e in extensions) names.set(e, language);
		add("Haxe", ["hx"]); add("RayScript", ["rays"]); add("JSON", ["json", "rayext", "raytheme", "jsonc", "json5"]);
		add("HXML", ["hxml"]); add("TOML", ["toml", "cbproj"]); add("YAML", ["yaml", "yml"]); add("INI", ["ini", "cfg", "conf", "config", "properties", "editorconfig"]);
		add("Markdown", ["md", "markdown", "mdown", "mkd", "mdx"]); add("HTML", ["html", "htm", "xhtml"]); add("CSS", ["css"]); add("SCSS", ["scss"]); add("Sass", ["sass"]); add("Less", ["less"]);
		add("JavaScript", ["js", "mjs", "cjs"]); add("JavaScript React", ["jsx"]); add("TypeScript", ["ts", "mts", "cts"]); add("TypeScript React", ["tsx"]); add("Vue", ["vue"]); add("Svelte", ["svelte"]);
		add("Java", ["java"]); add("Python", ["py", "pyw", "pyi"]); add("C", ["c", "h"]); add("C++", ["cpp", "cc", "cxx", "hpp", "hh", "hxx"]); add("C#", ["cs", "csx"]);
		add("Rust", ["rs"]); add("Go", ["go"]); add("Ruby", ["rb", "rake", "gemspec"]); add("Kotlin", ["kt", "kts"]); add("Swift", ["swift"]); add("Dart", ["dart"]); add("Lua", ["lua"]); add("Wren", ["wren"]);
		add("Perl", ["pl", "pm", "pod"]); add("Scala", ["scala", "sc"]); add("Haskell", ["hs", "lhs"]); add("Elixir", ["ex", "exs"]); add("Erlang", ["erl", "hrl"]); add("OCaml", ["ml", "mli"]);
		add("F#", ["fs", "fsi", "fsx"]); add("Clojure", ["clj", "cljs", "cljc", "edn"]); add("Julia", ["jl"]); add("R", ["r", "rmd"]); add("Zig", ["zig", "zon"]); add("Elm", ["elm"]); add("Nim", ["nim", "nims"]);
		add("Fortran", ["f", "for", "f90", "f95", "f03", "f08"]); add("CoffeeScript", ["coffee", "litcoffee"]); add("Nix", ["nix"]); add("GraphQL", ["graphql", "gql"]); add("LaTeX", ["tex", "sty", "cls", "bib"]);
		add("Objective-C", ["m", "mm"]); add("Groovy", ["groovy", "gvy", "gradle"]); add("Solidity", ["sol"]); add("PHP", ["php", "phtml"]); add("Shell Script", ["sh", "bash", "zsh", "fish"]);
		add("Batch", ["bat", "cmd"]); add("PowerShell", ["ps1"]); add("SQL", ["sql"]); add("XML", ["xml", "svg", "xsl", "plist"]); add("Plain Text", ["txt", "log", "rst", "adoc"]); add("CSV", ["csv", "tsv"]);
		names;
	};

	public static function of(file:Null<String>):Null<String> {
		if (file == null || file == "" || ImagePreview.isRaster(file)) return null;
		var name = haxe.io.Path.withoutDirectory(file).toLowerCase();
		if (BY_NAME.exists(name)) return BY_NAME.get(name);
		var language = BY_EXTENSION.get(haxe.io.Path.extension(name));
		return language == null ? "Plain Text" : language;
	}
}
