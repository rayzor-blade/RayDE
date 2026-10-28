package rayde.run;

import rayde.settings.Store;
import rayde.project.ProjectRunner;

typedef RunConfiguration = {
	target:String,
	compiler:String,
	framework:String,
	mode:String,
	runner:String,
	executable:String,
	flags:Array<String>,
	arguments:Array<String>,
	compilerFlags:Array<String>,
	buildCommand:String,
	buildFlags:Array<String>,
	program:String,
	previewDirectory:String,
	previewEntry:String
};

/** Target settings shared by Run, Build and Preview. Presets are editable values. */
class RunConfigurations {
	public static final modes = ["process", "aot", "browser"];
	public static final runners = [
		"auto",
		"ash",
		"hashlink",
		"node",
		"neko",
		"python",
		"lua",
		"php",
		"java",
		"mono",
		"native",
		"browser",
		"rayzor",
		"custom"
	];
	public static final frameworks = [
		"haxe",
		"ash",
		"ashui",
		"heaps",
		"openfl",
		"flixel",
		"lime",
		"ceramic",
		"tink",
		"rayzor",
		"caribou",
		"custom"
	];
	public static final targets = rayde.build.HxmlFile.targets.copy();
	public static final rayzorTargets = [
		"native",
		"aarch64-apple-darwin",
		"x86_64-apple-darwin",
		"x86_64-unknown-linux-gnu",
		"aarch64-unknown-linux-gnu",
		"x86_64-pc-windows-msvc",
		"wasm",
		"wasm-wasi"
	];

	public static function framework(root:String):String {
		var value:Dynamic = Store.section(root, "run").framework;
		return Std.isOfType(value, String) ? value : "haxe";
	}

	public static function hostSystem():String {
		#if (wasm || rayde_page)
		var client = rayde.workspace.PageHost.session;
		if (client != null && client.hostSystem != "")
			return client.hostSystem;
		#end
		return Sys.systemName();
	}

	public static function defaults(target:String, preview = false, legacy = "auto"):RunConfiguration {
		var runner = switch target {
			case "hl": preview ? "ash" : legacy;
			case "js": "node";
			case "neko": "neko";
			case "python": "python";
			case "lua": "lua";
			case "php": "php";
			case "jvm" | "java": "java";
			case "cpp": "native";
			case "cs": hostSystem() == "Windows" ? "native" : "mono";
			case _: "custom";
		};
		var value:RunConfiguration = {
			target: target,
			compiler: "haxe",
			framework: "haxe",
			mode: preview ? "browser" : "process",
			runner: runner,
			executable: "",
			flags: [],
			arguments: [],
			compilerFlags: [],
			buildCommand: "",
			program: "",
			buildFlags: [],
			previewDirectory: "",
			previewEntry: "index.html"
		};
		if (target == "hl") {
			if (preview)
				value.buildFlags = ["-O3", "--codegen-opt-level", "0", "--target", "wasm32-wasip1-threads"];
			else if (runner == "ash" || runner == "auto" && ProjectRunner.defaultHashlink() == "ash")
				value.flags = ["--preset", "application"];
		}
		if (target == "jvm" || target == "java")
			value.flags = ["-jar"];
		if (preview && target == "js")
			value.runner = "browser";
		return value;
	}

	public static function load(root:String, target:String, preview = false, ?family:String):RunConfiguration
		return from(Store.section(root, "run"), target, preview, family);

	public static function from(section:Dynamic, target:String, preview = false, ?family:String):RunConfiguration {
		var legacy:Dynamic = section.runner;
		var value = RunPresets.make(Std.isOfType(section.framework, String) ? section.framework : "haxe", target, preview,
			ProjectRunner.choices.indexOf(legacy) >= 0 ? legacy : "auto");
		if (family == "rayzor") {
			var label = value.framework;
			value = RunPresets.make("rayzor", target, preview);
			value.framework = label == "haxe" ? "rayzor" : label;
		}
		var group = Reflect.field(section, preview ? "previews" : "targets"),
			raw:Dynamic = group == null ? null : Reflect.field(group, target);
		if (raw == null && preview && section.targets != null) {
			var active = Reflect.field(section.targets, target);
			if (active != null && active.mode == "browser")
				raw = active;
		}
		if (raw == null)
			return value;
		if (!object(raw))
			throw "Invalid Run Configuration: " + target;
		for (field in [
			"compiler",
			"framework",
			"runner",
			"mode",
			"executable",
			"buildCommand",
			"program",
			"previewDirectory",
			"previewEntry"
		])
			if (Reflect.hasField(raw, field)) {
				var text = Reflect.field(raw, field);
				if (!Std.isOfType(text, String))
					throw "Run Configuration " + field + " must be text.";
				Reflect.setField(value, field, text);
			}
		if (!Reflect.hasField(raw, "flags") && target == "hl")
			value.flags = defaults(target, preview, value.runner).flags;
		for (field in ["flags", "arguments", "compilerFlags", "buildFlags"])
			if (Reflect.hasField(raw, field))
				Reflect.setField(value, field, strings(Reflect.field(raw, field)));
		if (family == "rayzor")
			value.compiler = "rayzor";
		validate(value);
		return value;
	}

	public static function save(root:String, value:RunConfiguration, preview = false):Void {
		validate(value);
		var section = Store.section(root, "run");
		section.framework = value.framework;
		if (value.compiler == "rayzor")
			Reflect.setField(section, preview ? "previewTarget" : "target", value.target);
		var key = preview ? "previews" : "targets";
		if (!object(Reflect.field(section, key)))
			Reflect.setField(section, key, {});
		Reflect.setField(Reflect.field(section, key), value.target, value);
		Store.saveChecked(root, "run", section);
	}

	/** Starter metadata configures files; it never starts a command. */
	public static function install(files:Map<String, String>, metadata:Dynamic):Void {
		if (!object(metadata))
			throw "Starter run metadata must be an object.";
		var encoded = haxe.Json.stringify(metadata);
		if (encoded.length > 128 * 1024)
			throw "Starter run metadata exceeds 128 KiB.";
		for (group in ["targets", "previews"])
			if (Reflect.hasField(metadata, group)) {
				var values = Reflect.field(metadata, group);
				if (!object(values))
					throw "Starter run targets must be an object.";
				for (target in Reflect.fields(values))
					from(metadata, target, group == "previews");
			}
		var path = ".rayde/settings.json",
			all:Dynamic = files.exists(path) ? haxe.Json.parse(files.get(path)) : {};
		if (!object(all))
			throw "Starter settings must be an object.";
		if (!object(all.run))
			all.run = {};
		for (field in Reflect.fields(metadata)) {
			if (field == "targets" || field == "previews") {
				if (!object(Reflect.field(all.run, field)))
					Reflect.setField(all.run, field, {});
				for (target in Reflect.fields(Reflect.field(metadata, field)))
					Reflect.setField(Reflect.field(all.run, field), target, Reflect.field(Reflect.field(metadata, field), target));
			} else
				Reflect.setField(all.run, field, Reflect.field(metadata, field));
		}
		files.set(path, haxe.Json.stringify(all, null, "\t") + "\n");
	}

	public static function validate(value:RunConfiguration):Void {
		if (!~/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}$/.match(value.target))
			throw "Invalid Run Configuration target name.";
		if (modes.indexOf(value.mode) < 0
			|| runners.indexOf(value.runner) < 0
			|| ["haxe", "rayzor", "caribou", "custom"].indexOf(value.compiler) < 0)
			throw "Unknown Run Configuration compiler, mode or runner.";
		for (field in [
			"framework",
			"executable",
			"buildCommand",
			"program",
			"previewDirectory",
			"previewEntry"
		]) {
			var text:String = Reflect.field(value, field);
			if (text.indexOf("\x00") >= 0 || text.length > 4096)
				throw "Invalid Run Configuration " + field;
		}
		strings(value.flags);
		strings(value.arguments);
		strings(value.compilerFlags);
		strings(value.buildFlags);
	}

	static function object(value:Dynamic):Bool
		return value != null && Reflect.isObject(value) && !Std.isOfType(value, Array) && !Std.isOfType(value, String);

	static function strings(value:Dynamic):Array<String> {
		if (!Std.isOfType(value, Array))
			throw "Run Configuration arguments must be an array of strings.";
		var result:Array<String> = [];
		for (item in (value : Array<Dynamic>)) {
			if (!Std.isOfType(item, String) || (item : String).indexOf("\x00") >= 0 || (item : String).length > 32768)
				throw "Invalid Run Configuration argument.";
			result.push(item);
		}
		if (result.length > 4096)
			throw "Too many Run Configuration arguments.";
		return result;
	}

	public static function runner(value:RunConfiguration):String
		return value.runner == "auto" ? (value.target == "hl" ? ProjectRunner.defaultHashlink() : defaults(value.target).runner) : value.runner;

	public static function executable(value:RunConfiguration, ?ash:String, ?hashlink:String):String {
		if (StringTools.trim(value.executable) != "")
			return value.executable;
		return switch runner(value) {
			case "ash": ash ?? Sys.getEnv("ASH") ?? "ash";
			case "hashlink": hashlink ?? Sys.getEnv("HL") ?? "hl";
			case "node": "node";
			case "neko": "neko";
			case "python": "python3";
			case "lua": "lua";
			case "php": "php";
			case "java": "java";
			case "mono": "mono";
			case "rayzor": rayde.lang.RayzorBinary.find() ?? "rayzor";
			case _: throw "Set the runner executable in Build Settings > Run Configuration.";
		};
	}

	/** Shell-like quoting for argument entry; commands are always launched as argument arrays. */
	public static function parse(text:String):Array<String> {
		if (StringTools.startsWith(StringTools.trim(text), "["))
			return strings(haxe.Json.parse(text));
		var result:Array<String> = [], word = "", quote = "", escaped = false, started = false;
		for (at in 0...text.length) {
			var character = text.charAt(at);
			if (escaped) {
				word += character;
				escaped = false;
				started = true;
				continue;
			}
			if (character == "\\" && quote != "'" && [" ", "\t", "\n", "\\", '"', "'"].indexOf(text.charAt(at + 1)) >= 0) {
				escaped = true;
				started = true;
				continue;
			}
			if (quote != "") {
				if (character == quote)
					quote = "";
				else
					word += character;
				started = true;
				continue;
			}
			if (character == "'" || character == '"') {
				quote = character;
				started = true;
				continue;
			}
			if (character == " " || character == "\t" || character == "\n" || character == "\r") {
				if (started) {
					result.push(word);
					word = "";
					started = false;
				}
			} else {
				word += character;
				started = true;
			}
		}
		if (escaped || quote != "")
			throw "Close the quote or escape in the arguments.";
		if (started)
			result.push(word);
		return result;
	}

	public static function format(args:Array<String>):String {
		if (Lambda.exists(args, value -> value.indexOf("\n") >= 0 || value.indexOf("\r") >= 0 || value.indexOf("\t") >= 0))
			return haxe.Json.stringify(args);
		var plain = new EReg("^[a-zA-Z0-9_./:=+-]+$", "");
		return args.map(value -> plain.match(value) ? value : haxe.Json.stringify(value)).join(" ");
	}
}
