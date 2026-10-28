package rayde.run;

import rayde.run.RunConfigurations.RunConfiguration;

/** Framework defaults populate the form once; saved fields remain the user's values. */
class RunPresets {
	public static function make(framework:String, target:String, preview = false, legacy = "auto"):RunConfiguration {
		var value = RunConfigurations.defaults(target, preview, legacy);
		value.framework = framework;
		switch framework {
			case "ash" | "ashui" if (target == "hl"):
				value.runner = "ash";
				value.flags = preview ? [] : ["--preset", "application"];
			case "heaps" | "tink" if (target == "js"):
				value.runner = "browser";
				value.mode = "browser";
				value.previewDirectory = ".";
			case "openfl" | "flixel" | "lime":
				var platform = switch target {
					case "js": "html5";
					case "swf": "flash";
					case _: target;
				};
				value.buildCommand = "haxelib";
				value.buildFlags = ["run", "lime", "build", platform];
				value.runner = "custom";
				value.executable = "haxelib";
				value.flags = ["run", "lime", "run", platform];
				value.compiler = "custom";
				value.previewDirectory = "bin/html5/bin";
				if (preview && target == "js") {
					value.mode = "browser";
					value.runner = "browser";
				}
			case "ceramic":
				var platform = switch target {
					case "js": "web";
					case "cpp": switch RunConfigurations.hostSystem() {
							case "Mac": "mac";
							case "Windows": "windows";
							case _: "linux";
						};
					case _: target;
				};
				value.compiler = "custom";
				value.buildCommand = "ceramic";
				value.buildFlags = ["clay", "build", platform, "--setup", "--assets"];
				value.runner = "custom";
				value.executable = "ceramic";
				value.flags = ["clay", "run", platform, "--setup", "--assets"];
				value.previewDirectory = "project/web";
				if (preview && target == "js") {
					value.mode = "browser";
					value.runner = "browser";
				}
			case "rayzor":
				value.compiler = "rayzor";
				value.runner = "rayzor";
				value.flags = [];
				if (preview || StringTools.startsWith(target, "wasm")) {
					value.mode = "browser";
					value.buildFlags = [
						"build",
						"--target",
						["wasm", "wasm-wasi", "wasm32"].indexOf(target) >= 0 ? target : "wasm",
						"--browser"
					];
					value.previewEntry = "app.html";
				} else if (target != "native") {
					value.mode = "aot";
					value.buildFlags = ["aot", "--target", target];
				}
			case "caribou":
				value.compiler = "caribou";
				value.buildCommand = "caribou";
				value.buildFlags = ["build"];
				value.runner = "custom";
				value.executable = "caribou";
				value.flags = ["run"];
			case _:
		}
		return value;
	}

	public static function starter(id:String):Dynamic {
		var framework = switch id {
			case "javascript": "tink";
			case "hxml" | "hashlink" | "haxelib": "haxe";
			case _: id;
		};
		var target = switch id {
			case "heaps" | "javascript" | "openfl" | "flixel" | "lime" | "ceramic": "js";
			case "rayzor": "native";
			case _: "hl";
		};
		var metadata:Dynamic = {
			framework: framework,
			target: target,
			targets: {},
			previews: {}
		};
		var normal = make(framework, target);
		if (normal.runner == "auto") {
			normal.runner = "auto";
			Reflect.deleteField(normal, "flags");
		}
		if (["openfl", "flixel", "lime"].indexOf(id) >= 0)
			normal.previewDirectory = "Export/html5/bin";
		Reflect.setField(metadata.targets, target, normal);
		if (target == "js" || framework == "ashui" || framework == "ash" || framework == "rayzor") {
			var browser = make(framework, target, true);
			if (["openfl", "flixel", "lime"].indexOf(id) >= 0)
				browser.previewDirectory = "Export/html5/bin";
			Reflect.setField(metadata.previews, target, browser);
		}
		return metadata;
	}
}
