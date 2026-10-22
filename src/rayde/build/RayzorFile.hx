package rayde.build;

import haxe.io.Bytes;
import sys.io.File;

/** A Rayzor manifest edited one field at a time, keeping unrelated TOML intact. */
class RayzorFile {
	public final path:String;
	var data:Dynamic;

	public function new(path:String) {
		this.path = path;
		reload();
	}

	public function reload():Void {
		var bytes = Bytes.ofString(source());
		data = unpack(parseNative(bytes.getData(), bytes.length)).value;
		if (value(["project"]) == null && value(["workspace"]) == null) throw "rayzor.toml needs a [project] or [workspace] section";
	}

	public function value(path:Array<String>):Dynamic {
		var at:Dynamic = data;
		for (key in path) { if (at == null) return null; at = Reflect.field(at, key); }
		return at;
	}

	public function text(path:Array<String>):String {
		var v:Dynamic = value(path);
		return v == null ? "" : Std.string(v);
	}

	public function strings(path:Array<String>):Array<String> {
		var v:Dynamic = value(path);
		if (v == null) return [];
		if (!Std.isOfType(v, Array)) throw path.join(".") + " must be an array of strings";
		return [for (s in (v:Array<Dynamic>)) {
			if (!Std.isOfType(s, String)) throw path.join(".") + " must contain strings";
			(s:String);
		}];
	}

	public function workspace():Bool return value(["workspace"]) != null;
	public function set(path:Array<String>, value:Dynamic):Void edit({path:path, value:value});
	public function append(path:Array<String>, value:String):Void edit({path:path, value:value, action:"append"});
	public function removeAt(path:Array<String>, index:Int):Void edit({path:path, index:index, action:"remove-index"});

	function source():String {
		if (sys.FileSystem.stat(path).size > 2 * 1024 * 1024) throw "Project manifest exceeds 2 MiB";
		return File.getContent(path);
	}

	/** Read the current file before every edit so external changes are preserved. */
	function edit(request:Dynamic):Void {
		Reflect.setField(request, "source", source());
		var bytes = Bytes.ofString(haxe.Json.stringify(request));
		var result = unpack(editNative(bytes.getData(), bytes.length));
		File.saveContent(path, result.source);
		reload();
	}

	static function unpack(bytes:hl.Bytes):Dynamic {
		if (bytes == null) throw "TOML operation failed";
		var length = bytes.getI32(0), result:Dynamic = haxe.Json.parse(bytes.sub(4, length).toBytes(length).toString());
		if (result.error != null) throw Std.string(result.error);
		return result;
	}

	@:hlNative("rayscript", "project_toml") static function parseNative(data:hl.Bytes, length:Int):hl.Bytes return null;
	@:hlNative("rayscript", "project_toml_edit") static function editNative(data:hl.Bytes, length:Int):hl.Bytes return null;
}
