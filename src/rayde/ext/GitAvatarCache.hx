package rayde.ext;

import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;
import rayde.ext.GitProfiles.GitProfile;

typedef SavedAvatar = {profile:GitProfile, saved:Float};

/** Compressed public images only; all disk access belongs to the profile worker. */
class GitAvatarCache {
	public static inline var FRESH_SECONDS = 7 * 86400;
	static inline var MAX_IMAGE = 256 * 1024;
	static inline var MAX_FILE = 360 * 1024;
	static inline var MAX_BYTES = 8 * 1024 * 1024;
	static inline var MAX_ENTRIES = 128;

	public static function path(directory:String, key:String):String
		return haxe.io.Path.join([directory,haxe.crypto.Sha256.encode(key) + ".json"]);

	public static function read(directory:String, key:String):Null<SavedAvatar> {
		var file = path(directory,key);
		try {
			if (!FileSystem.exists(file)) return null;
			if (FileSystem.stat(file).size > MAX_FILE) throw "Avatar cache entry is too large";
			var value:Dynamic = haxe.Json.parse(File.getContent(file));
			if (value.version != 1 || !Std.isOfType(value.name,String) || (value.name:String).length > 200 ||
				!Std.isOfType(value.image,String) || !Std.isOfType(value.saved,Float) || !Std.isOfType(value.hash,String)) throw "Invalid avatar cache entry";
			if (!Math.isFinite(value.saved) || value.saved < 0) throw "Invalid avatar cache timestamp";
			var bytes = haxe.crypto.Base64.decode(value.image);
			if (bytes.length == 0 || bytes.length > MAX_IMAGE || haxe.crypto.Sha256.make(bytes).toHex() != value.hash) throw "Invalid cached avatar bytes";
			return {profile:{name:value.name,bytes:bytes},saved:value.saved};
		} catch (_:Dynamic) {
			try FileSystem.deleteFile(file) catch (_:Dynamic) {}
			return null;
		}
	}

	public static function save(directory:String, key:String, profile:GitProfile):Void {
		if (profile == null || profile.bytes.length == 0 || profile.bytes.length > MAX_IMAGE) return;
		var file = path(directory,key), temporary = file + ".tmp-" + Std.random(0x3fffffff);
		try {
			FileSystem.createDirectory(directory);
			File.saveContent(temporary,haxe.Json.stringify({version:1,name:profile.name.substr(0,200),saved:Sys.time(),
				image:haxe.crypto.Base64.encode(profile.bytes),hash:haxe.crypto.Sha256.make(profile.bytes).toHex()}));
			FileSystem.rename(temporary,file);
			trim(directory);
		} catch (_:Dynamic) {
			try FileSystem.deleteFile(temporary) catch (_:Dynamic) {}
		}
	}

	static function trim(directory:String):Void {
		var entries:Array<{path:String,size:Int,modified:Float}> = [];
		for (name in FileSystem.readDirectory(directory)) if (~/^[a-f0-9]{64}\.json$/.match(name)) {
			var file = haxe.io.Path.join([directory,name]);
			try {
				var info = FileSystem.stat(file);
				if (!FileSystem.isDirectory(file)) entries.push({path:file,size:info.size,modified:info.mtime.getTime()});
			} catch (_:Dynamic) {}
		}
		entries.sort((a,b) -> a.modified != b.modified ? Reflect.compare(b.modified,a.modified) : Reflect.compare(a.path,b.path));
		var count = 0, bytes = 0;
		for (entry in entries) {
			if (count < MAX_ENTRIES && bytes + entry.size <= MAX_BYTES) { count++; bytes += entry.size; }
			else try FileSystem.deleteFile(entry.path) catch (_:Dynamic) {}
		}
	}
}
