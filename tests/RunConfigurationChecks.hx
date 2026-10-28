import rayde.run.RunConfigurations;
import rayde.run.RunPlan;
import rayde.run.RunPresets;
import rayde.run.Runner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.settings.Store;

class RunConfigurationChecks {
	static function check(value:Bool, message:String):Void
		if (!value)
			throw message;

	static function main():Void {
		var arguments = [
			"--flag",
			"space here",
			"",
			'C:\\SDK\\path',
			"literal $(false)",
			"quote'\"value",
			"λ"
		];
		check(haxe.Json.stringify(RunConfigurations.parse(RunConfigurations.format(arguments))) == haxe.Json.stringify(arguments),
			"Argument quoting did not roundtrip literal values");
		check(RunConfigurations.parse('--sysroot C:\\SDK')[1] == 'C:\\SDK', "Windows path backslashes were stripped");
		var control = ["one\ntwo"];
		check(RunConfigurations.parse(RunConfigurations.format(control))[0] == control[0], "JSON arguments lost control characters");
		for (target in RunConfigurations.targets) {
			var config = RunConfigurations.defaults(target);
			config.runner = "custom";
			config.executable = "configured-runner";
			config.flags = ["--flag", "value with spaces"];
			config.arguments = ["literal $(false)"];
			var args = ["-cp", "xhl", "-main", "app.Main", "--" + target];
			if (target != "interp")
				args.push("bin/output");
			var plan = RunPlan.make("configured-haxe", args, "/workspace", "/workspace/.rayde/run", config);
			check(plan.compile.command == "configured-haxe"
				&& plan.compile.args.indexOf("--" + target) >= 0, "Compiler target was replaced: " + target);
			if (target != "hl")
				check(plan.compile.args.indexOf("--hl") < 0, "Non-HashLink target was routed through bytecode");
			if (target != "interp")
				check(plan.launch.command == "configured-runner"
					&& plan.launch.args.indexOf("value with spaces") >= 0
					&& plan.launch.args[plan.launch.args.length - 1] == "literal $(false)",
					"Runner flags or program arguments were dropped: "
					+ target);
		}
		var preview = RunPresets.make("ashui", "hl", true);
		var browserPlan = RunPlan.make("haxe", ["-main", "Main", "-hl", "old.hl"], "/workspace", "/workspace/.rayde/preview", preview, true, "/support", true);
		check(browserPlan.postBuild.args.indexOf("-O3") >= 0
			&& browserPlan.postBuild.args[browserPlan.postBuild.args.indexOf("--codegen-opt-level") + 1] == "0",
			"Ash preview did not keep LLVM optimization with faster codegen");
		check(browserPlan.compile.args.indexOf("--codegen-opt-level") < 0, "Ash optimization flags reached the Haxe compiler");
		var explicitProfile = RunConfigurations.from({previews: {hl: {buildFlags: ["-Oz", "--target", "wasm32-wasip1-threads"]}}}, "hl", true);
		check(explicitProfile.buildFlags.indexOf("-Oz") >= 0 && explicitProfile.buildFlags.indexOf("--codegen-opt-level") < 0,
			"Preview defaults replaced an explicit optimization choice");
		var aot = RunPresets.make("ashui", "hl");
		aot.mode = "aot";
		aot.buildFlags = ["--target", "aarch64-apple-darwin", "--no-fma"];
		aot.arguments = ["hello"];
		var native = RunPlan.make("haxe", ["-main", "Main", "-hl", "bin/app.hl"], "/workspace", "/workspace/.rayde/run", aot);
		check(native.postBuild.args.indexOf("--no-fma") >= 0
			&& native.postBuild.args.indexOf("aarch64-apple-darwin") >= 0, "Ash AOT flags were lost");
		check(native.launch.command == native.output && native.launch.args[0] == "hello", "AOT did not launch the compiled executable");
		var rayzor = RunPresets.make("rayzor", "x86_64-unknown-linux-gnu");
		rayzor.executable = "configured-rayzor";
		var direct = RunPlan.make("must-not-call-haxe", ["--js", "editor-only.js"], "/workspace", "/workspace/.rayde/run", rayzor);
		check(direct.compile.command == "configured-rayzor"
			&& direct.compile.args[0] == "aot"
			&& direct.compile.args.indexOf("x86_64-unknown-linux-gnu") >= 0,
			"Rayzor target triple was not passed to its compiler");
		check(direct.compile.args.indexOf("--js") < 0 && direct.compile.args.indexOf("--hl") < 0, "Rayzor inherited Haxe editor flags");
		var csharp = RunConfigurations.defaults("cs");
		check(csharp.runner == (Sys.systemName() == "Windows" ? "native" : "mono"), "C# runner did not follow the workspace host");
		var wrapped = RunConfigurations.defaults("cpp");
		wrapped.executable = "configured-launcher";
		var wrappedPlan = RunPlan.make("haxe", ["-main", "Main", "--cpp", "bin/cpp"], "/workspace", "/workspace/.rayde/run", wrapped);
		check(wrappedPlan.launch.args[0] == wrappedPlan.program, "A native launcher override lost its program argument");
		var browserRayzor = RunPresets.make("rayzor", "aarch64-apple-darwin", true);
		check(browserRayzor.buildFlags.indexOf("wasm") >= 0, "Rayzor browser preset sent a native LLVM triple to its WASM builder");
		var ceramic = RunPresets.make("ceramic", "cpp");
		check(ceramic.buildFlags[2] == (Sys.systemName() == "Mac" ? "mac" : Sys.systemName() == "Windows" ? "windows" : "linux"),
			"Ceramic native preset did not select the host platform");
		var files = [".rayde/settings.json" => '{"appearance":{"scheme":"dark"},"run":{"keep":true}}'];
		RunConfigurations.install(files, RunPresets.starter("ashui"));
		var metadata:Dynamic = haxe.Json.parse(files.get(".rayde/settings.json"));
		check(metadata.appearance.scheme == "dark"
			&& metadata.run.keep
			&& metadata.run.targets.hl.runner == "ash"
			&& metadata.run.previews.hl.mode == "browser",
			"Starter metadata overwrote settings or omitted target/preview profiles");
		var lime = RunPresets.make("openfl", "js", true);
		check(lime.buildCommand == "haxelib" && lime.buildFlags.join(" ") == "run lime build html5" && lime.mode == "browser",
			"OpenFL did not select its framework compiler");
		processes();
		Sys.println("Run configurations: all Haxe targets, quoting, Ash AOT, Rayzor triples, framework presets, starter metadata and JS/Python execution passed");
	}

	static function finish(runner:Runner):Void {
		var end = haxe.Timer.stamp() + 30;
		while (runner.active() && haxe.Timer.stamp() < end) {
			runner.tick();
			Sys.sleep(.005);
		}
		check(runner.state == "finished" && runner.exitCode == 0, "Configured execution failed: " + runner.console);
	}

	static function processes():Void {
		var root = Sys.getCwd() + "bin/run-config-" + Std.random(0x3fffffff);
		sys.FileSystem.createDirectory(root + "/src");
		sys.io.File.saveContent(root + "/src/Main.hx", 'class Main {static function main(){trace("CONFIGURED_TARGET_RAN");}}');
		var compiler = new CompilerServer();
		try {
			for (target in ["js", "python"]) {
				var file = root + "/build.hxml";
				sys.io.File.saveContent(file, "-cp src\n-main Main\n--" + target + " bin/program." + (target == "js" ? "js" : "py") + "\n");
				var config = RunConfigurations.defaults(target);
				config.arguments = ["literal $(false)", "space here"];
				RunConfigurations.save(root, config);
				var runner = new Runner(Display.ofHxml(compiler, file));
				runner.start();
				finish(runner);
				check(runner.console.indexOf("CONFIGURED_TARGET_RAN") >= 0, "Target program did not run: " + target);
			}
			var aotFile = root + "/build.hxml";
			sys.io.File.saveContent(aotFile, "-cp src\n-main Main\n-hl bin/program.hl\n-dce full\n");
			sys.io.File.saveContent(root + "/src/Main.hx", 'class Main {static function main(){trace("NATIVE_AOT_RAN:"+Sys.args().join("|"));}}');
			var aot = RunPresets.make("ash", "hl");
			aot.mode = "aot";
			aot.buildFlags = ["--no-fma"];
			aot.arguments = ["literal $(false)", "space here"];
			RunConfigurations.save(root, aot);
			var aotRunner = new Runner(Display.ofHxml(compiler, aotFile));
			aotRunner.start();
			finish(aotRunner);
			check(aotRunner.console.indexOf("NATIVE_AOT_RAN:literal $(false)|space here") >= 0,
				"Ash AOT did not execute the native artifact with configured arguments");
		} catch (error:Dynamic) {
			compiler.stop();
			throw error;
		}
		compiler.stop();
	}
}
