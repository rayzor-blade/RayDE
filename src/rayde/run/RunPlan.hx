package rayde.run;

import haxe.io.Path;
import rayde.run.RunConfigurations.RunConfiguration;

typedef RunCommand = {command:String, args:Array<String>, phase:String};
typedef PlannedRun = {configuration:RunConfiguration, compile:Null<RunCommand>, postBuild:Null<RunCommand>, launch:Null<RunCommand>, program:String,
	output:String};

/** Target-aware command planning shared by process supervision and preview surfaces. */
class RunPlan {
	static final kinds = RunConfigurations.targets;

	public static function target(args:Array<String>):{kind:String, output:Null<String>} {
		for (at in 0...args.length) {
			var flag = args[at],
				kind = flag.substr(flag.indexOf("--") == 0 ? 2 : 1);
			if (flag.charAt(0) == "-" && kinds.indexOf(kind) >= 0)
				return {kind: kind, output: kind == "interp" ? null : args[at + 1]};
			if (flag == "--no-output")
				return {kind: "none", output: null};
		}
		return {kind: "hl", output: null};
	}

	public static function selected(root:String, args:Array<String>, ?family:String, preview = false):String {
		if (family == "rayzor" || args.length == 0) {
			var section = rayde.settings.Store.section(root, "run"),
				value:Dynamic = preview && section.previewTarget != null ? section.previewTarget : section.target;
			if (Std.isOfType(value, String))
				return value;
		}
		return family == "rayzor" ? "native" : target(args).kind;
	}

	public static function make(compiler:String, args:Array<String>, root:String, out:String, value:RunConfiguration, preview = false, ?support:String,
			buildOnly = false):PlannedRun {
		RunConfigurations.validate(value);
		if (value.compiler == "rayzor")
			return rayzor(root, out, value, buildOnly);
		var target = value.target,
			main = mainClass(args),
			declared = RunPlan.target(args);
		var program = value.program != "" ? full(root, value.program) : declared.output == null ? out
			+ "/program."
			+ extension(target) : full(root, declared.output);
		if (target == "hl" && (preview || value.program == ""))
			program = out + (preview ? "/app.hl" : "/program.hl");
		else if (preview)
			program = out
				+ "/"
				+ (target == "js"
					&& declared.output != null
					&& !Path.isAbsolute(declared.output)
					&& declared.output.split("/").indexOf("..") < 0 ? declared.output : "app." + extension(target));
		else if (value.program == "" && declared.output != null)
			program = switch target {
				case "cpp": program + "/" + main + (args.indexOf("--debug") >= 0 || args.indexOf("-debug") >= 0 ? "-debug" : "");
				case "cs": program + "/bin/" + main + ".exe";
				case "java": program + "/" + main + ".jar";
				case "php": program + "/index.php";
				case _: program;
			};
		var compilation:RunCommand;
		if (value.buildCommand != "")
			compilation = {command: value.buildCommand, args: expand(value.buildFlags.concat(value.compilerFlags), root, program, out,
				target), phase: "Building with "
				+ value.framework};
		else {
			var inputs = args.concat(value.compilerFlags);
			if (target == "hl" || preview || declared.output == null && target != "interp" && target != "none")
				inputs = compilerArgs(inputs, target, program, value.mode == "browser", support);
			compilation = {command: compiler, args: inputs, phase: "Compiling Haxe"};
		}
		var result:PlannedRun = {
			configuration: value,
			compile: compilation,
			postBuild: null,
			launch: null,
			program: program,
			output: program
		};
		if (value.mode == "aot" || value.mode == "browser" && target == "hl" && value.buildCommand == "") {
			if (target != "hl")
				throw "Choose a framework build command for this target's native or browser output.";
			if (RunConfigurations.runner(value) == "hashlink")
				throw "HashLink does not compile native or browser output. Choose the appropriate compiler runner.";
			result.output = out + (value.mode == "browser" ? "/app.wasm" : "/program");
			result.postBuild = {command: RunConfigurations.executable(value), args: ["--build", result.output].concat(expand(value.buildFlags, root, program,
				result.output, target))
				.concat([program]), phase: value.mode == "browser" ? "Compiling WASM" : "Compiling native executable"};
			if (!buildOnly && value.mode == "aot")
				result.launch = {command: result.output, args: value.arguments.copy(), phase: "Running"};
		} else if (!buildOnly && target != "interp" && target != "none" && value.mode != "browser" && value.runner != "browser") {
			var executable = value.runner == "native" && value.executable == "" ? program : RunConfigurations.executable(value);
			var parameters = expand(value.flags, root, program, result.output, target);
			if (value.buildCommand == "" && (value.runner != "native" || value.executable != ""))
				parameters.push(program);
			result.launch = {command: executable, args: parameters.concat(value.arguments), phase: "Running"};
		}
		return result;
	}

	/** Rayzor reads source and manifests itself; its target is an LLVM triple or WASM selector. */
	static function rayzor(root:String, out:String, value:RunConfiguration, buildOnly:Bool):PlannedRun {
		var binary = value.buildCommand != "" ? value.buildCommand : value.executable != "" ? value.executable : rayde.lang.RayzorBinary.find() ?? "rayzor";
		var output = out + (value.mode == "browser" ? "/app.wasm" : "/program");
		var result:PlannedRun = {
			configuration: value,
			compile: null,
			postBuild: null,
			launch: null,
			program: output,
			output: output
		};
		if (value.mode == "aot" || value.mode == "browser") {
			var options = value.buildFlags.length > 0 ? value.buildFlags.copy() : value.mode == "browser" ? ["build", "--target", value.target, "--browser"] : value.target == "native" ? ["aot"] : ["aot", "--target", value.target];
			result.compile = {command: binary, args: options.concat(value.compilerFlags).concat(["--output", output]), phase: "Compiling with Rayzor"};
			if (!buildOnly && value.mode == "aot")
				result.launch = {command: output, args: value.arguments.copy(), phase: "Running"};
		} else if (buildOnly)
			result.compile = {command: binary, args: ["build"].concat(value.buildFlags).concat(value.compilerFlags), phase: "Building with Rayzor"};
		else
			result.launch = {command: binary, args: ["run"].concat(value.flags)
				.concat(value.arguments.length == 0 ? [] : ["--"].concat(value.arguments)), phase: "Running with Rayzor"};
		return result;
	}

	public static function compilerArgs(args:Array<String>, target:String, output:String, browser = false, ?support:String):Array<String> {
		var result:Array<String> = [], at = 0;
		while (at < args.length) {
			var flag = args[at++],
				kind = flag.substr(flag.indexOf("--") == 0 ? 2 : 1);
			if (flag == "--next" || flag == "--each")
				throw "Select one compilation for this Run Configuration.";
			if (flag.charAt(0) == "-" && kinds.indexOf(kind) >= 0) {
				if (kind != "interp")
					at++;
				continue;
			}
			if (flag == "--no-output")
				continue;
			result.push(flag);
		}
		if (browser && target == "hl")
			result = result.concat(["-D", "wasm"]);
		if (support != null && target == "hl")
			result = result.concat(["-cp", support]);
		return result.concat(target == "interp" ? ["--interp"] : target == "none" ? ["--no-output"] : ["--" + target, output]);
	}

	static function mainClass(args:Array<String>):String {
		for (at in 0...args.length - 1)
			if (["-main", "--main", "-m"].indexOf(args[at]) >= 0) {
				var parts = args[at + 1].split(".");
				return parts[parts.length - 1];
			}
		return "Main";
	}

	public static function expand(args:Array<String>, root:String, program:String, output:String, target:String):Array<String>
		return args.map(value -> {
			for (key => replacement in ["root" => root, "program" => program, "output" => output, "target" => target])
				value = StringTools.replace(value, "{" + key + "}", replacement);
			return value;
		});

	static function full(root:String, path:String):String
		return Path.isAbsolute(path) ? path : Path.join([root, path]);

	static function extension(target:String):String
		return switch target {
			case "hl": "hl";
			case "js": "js";
			case "neko": "n";
			case "python": "py";
			case "lua": "lua";
			case "jvm": "jar";
			case "swf": "swf";
			case "cppia": "cppia";
			case _: "out";
		};
}
