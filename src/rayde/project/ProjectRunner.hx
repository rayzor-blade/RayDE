package rayde.project;

/** A workspace's bytecode runner, independent of its compiler target. */
class ProjectRunner {
	public static final choices = ["auto", "ash", "hashlink"];
	static var apple:Null<Bool>;
	public static function defaultHashlink(?system:String, ?appleSilicon:Bool):String {
		#if (wasm || rayde_page)
		// A page presents as a Mac with Apple silicon; its programs run on Ash.
		if (system == null) return "ash";
		#end
		if ((system ?? Sys.systemName()) != "Mac") return "hashlink";
		if (appleSilicon == null) { if (apple == null) apple = nativeAppleSilicon(); appleSilicon = apple; }
		return appleSilicon ? "ash" : "hashlink";
	}
	public static function preference(root:String):String {
		var value:Dynamic = rayde.settings.Store.section(root, "run").runner;
		return Std.isOfType(value, String) && choices.indexOf(value) >= 0 ? value : "auto";
	}
	public static function resolve(root:String):String {
		var value = preference(root);
		return value == "auto" ? defaultHashlink() : value;
	}
	public static function label(runner:String):String return runner == "hashlink" ? "HashLink (hl)" : "Ash";
	public static function configure(files:Map<String, String>, runner:String):Void {
		if (choices.indexOf(runner) < 0) throw "Runner must be auto, ash or hashlink";
		var path = ".rayde/settings.json", data:Dynamic = files.exists(path) ? haxe.Json.parse(files.get(path)) : {};
		if (!Reflect.isObject(data) || Std.isOfType(data, Array) || Std.isOfType(data, String)) throw "Starter settings must be an object";
		if (data.run == null) data.run = {};
		if (!Reflect.isObject(data.run) || Std.isOfType(data.run, Array) || Std.isOfType(data.run, String)) throw "Starter run settings must be an object";
		data.run.runner = runner;
		files.set(path, haxe.Json.stringify(data, null, "\t") + "\n");
	}
	@:hlNative("rayscript", "project_apple_silicon") static function nativeAppleSilicon():Bool return false;
}
