package rayde.ui;

/** Shared file icons for Explorer rows and editor tabs. */
class FileIcons {
	public static function of(file:String):ashui.svg.SvgDocument {
		var name = haxe.io.Path.withoutDirectory(file).toLowerCase(), extension = haxe.io.Path.extension(name);
		if (name == "dockerfile" || name == "containerfile") return Icons.INSTANCE_LINE;
		if (name == "makefile" || name == "justfile" || name == "cmakelists.txt") return Icons.TOOLS_LINE;
		if (name == "license" || name == "licence" || name == "copying") return Icons.COPYRIGHT_LINE;
		if (StringTools.startsWith(name, ".git")) return Icons.GIT_REPOSITORY_LINE;
		if (name == "package.json" || name == "package-lock.json" || name == "yarn.lock" || name == "pnpm-lock.yaml") return Icons.NPMJS_LINE;
		if (name == ".env" || StringTools.startsWith(name, ".env.")) return Icons.FILE_SETTINGS_LINE;
		return switch extension {
			case "hx": Icons.HAXE;
			case "rays", "rayext": Icons.PUZZLE_LINE;
			case "raytheme": Icons.PALETTE_LINE;
			case "hxml", "toml", "yaml", "yml", "ini", "cfg", "conf", "config", "properties", "editorconfig": Icons.FILE_SETTINGS_LINE;
			case "json", "jsonc", "json5": Icons.BRACES_LINE;
			case "md", "markdown", "mdown", "mkd", "mdx": Icons.MARKDOWN_LINE;
			case "html", "htm", "xhtml": Icons.HTML5_LINE;
			case "css", "scss", "sass", "less": Icons.CSS3_LINE;
			case "js", "mjs", "cjs": Icons.JAVASCRIPT_LINE;
			case "jsx", "tsx": Icons.REACTJS_LINE;
			case "vue": Icons.VUEJS_LINE;
			case "java", "jar", "class": Icons.JAVA_LINE;
			case "py", "pyw", "pyi", "ipynb": Icons.DEVICON_PYTHON;
			case "ts", "mts", "cts": Icons.DEVICON_TYPESCRIPT;
			case "c", "h": Icons.DEVICON_C;
			case "cpp", "cc", "cxx", "hpp", "hh", "hxx": Icons.DEVICON_CPLUSPLUS;
			case "cs", "csx": Icons.DEVICON_CSHARP;
			case "rs": Icons.DEVICON_RUST;
			case "go": Icons.DEVICON_GO;
			case "rb", "rake", "gemspec": Icons.DEVICON_RUBY;
			case "kt", "kts": Icons.DEVICON_KOTLIN;
			case "swift": Icons.DEVICON_SWIFT;
			case "dart": Icons.DEVICON_DART;
			case "lua": Icons.DEVICON_LUA;
			case "pl", "pm", "pod": Icons.DEVICON_PERL;
			case "scala", "sc": Icons.DEVICON_SCALA;
			case "hs", "lhs": Icons.DEVICON_HASKELL;
			case "ex", "exs": Icons.DEVICON_ELIXIR;
			case "erl", "hrl": Icons.DEVICON_ERLANG;
			case "ml", "mli": Icons.DEVICON_OCAML;
			case "fs", "fsi", "fsx": Icons.DEVICON_FSHARP;
			case "clj", "cljs", "cljc", "edn": Icons.DEVICON_CLOJURE;
			case "jl": Icons.DEVICON_JULIA;
			case "r", "rmd": Icons.DEVICON_R;
			case "zig", "zon": Icons.DEVICON_ZIG;
			case "elm": Icons.DEVICON_ELM;
			case "nim", "nims": Icons.DEVICON_NIM;
			case "f", "for", "f90", "f95", "f03", "f08": Icons.DEVICON_FORTRAN;
			case "coffee", "litcoffee": Icons.DEVICON_COFFEESCRIPT;
			case "svelte": Icons.DEVICON_SVELTE;
			case "nix": Icons.DEVICON_NIXOS;
			case "graphql", "gql": Icons.DEVICON_GRAPHQL;
			case "tex", "sty", "cls", "bib": Icons.DEVICON_LATEX;
			case "m", "mat": Icons.DEVICON_MATLAB;
			case "mm": Icons.DEVICON_OBJECTIVEC;
			case "groovy", "gvy", "gradle": Icons.DEVICON_GROOVY;
			case "sol": Icons.DEVICON_SOLIDITY;
			case "php", "phtml": Icons.PHP_LINE;
			case "sh", "bash", "zsh", "fish", "bat", "cmd", "ps1": Icons.TERMINAL_LINE;
			case "svg", "jpg", "jpeg", "jpe", "png", "bmp", "gif", "ico", "webp", "avif", "tif", "tiff", "heic", "icns": Icons.IMAGE_LINE;
			case "mp3", "wav", "ogg", "flac", "m4a", "aac", "mid", "midi", "aiff": Icons.FILE_MUSIC_LINE;
			case "mp4", "webm", "mov", "avi", "mkv", "m4v": Icons.FILE_VIDEO_LINE;
			case "zip", "gz", "bz2", "xz", "tar", "tgz", "7z", "rar": Icons.FILE_ZIP_LINE;
			case "pdf": Icons.FILE_PDF_LINE;
			case "doc", "docx", "odt", "rtf": Icons.FILE_WORD_LINE;
			case "xls", "xlsx", "ods", "csv", "tsv": Icons.FILE_EXCEL_LINE;
			case "ppt", "pptx", "odp": Icons.FILE_PPT_LINE;
			case "sql", "db", "sqlite", "sqlite3": Icons.DATABASE_LINE;
			case "txt", "log", "rst", "adoc": Icons.FILE_TEXT_LINE;
			case "ttf", "otf", "woff", "woff2": Icons.FONT_SIZE;
			case "pem", "key", "crt", "cer", "p12", "pfx": Icons.KEY_2_LINE;
			case "lock": Icons.LOCK_LINE;
			case _: Icons.FILE_CODE_LINE;
		}
	}
}
