package rayde.history;

import rayde.workspace.Fs;
import haxe.crypto.Sha256;
import rayde.history.LineOwners.HistoryJournal;

typedef Revision = {id:Int, parent:Int, time:Float, kind:String, from:Int, removed:String, inserted:String, ?author:String};
typedef HistoryEntry = {id:Int, time:Float, kind:String, ?author:String};
private typedef Journal = {version:Int, file:String, base:String, baseId:Int, baseTime:Float, revisions:Array<Revision>, savedHash:String, undo:Dynamic, ?baseOwners:Array<Null<String>>};
private typedef Cached = {data:Journal, text:String, modified:Bool};

/** Bounded per-file patch journals, independent of source control and editor/view ownership. */
class LocalHistory {
	public static inline var MAX_ENTRIES = 200;
	public static inline var MAX_BYTES = 8 * 1024 * 1024;
	final directory:String;
	final cache = new Map<String, Cached>();
	public var changed:Void->Void = () -> {};
	public var failed:String->Void = _ -> {};

	public function new(root:String) directory = root + "/.rayde/history";
	public function path(file:String):String return directory + "/" + Sha256.encode(file) + ".json";
	public function files():Array<String> return [for (file in cache.keys()) file];

	function load(file:String, disk:String):Cached {
		var cached = cache.get(file);
		if (cached != null) return cached;
		var now = Date.now().getTime(), data:Journal = {version:1, file:file, base:disk, baseId:0, baseTime:now, revisions:[], savedHash:Sha256.encode(disk), undo:null}, text = disk;
		var name = path(file);
		if (Fs.exists(name)) try {
			if (Fs.stat(name).size > MAX_BYTES) throw "Local history file exceeds its size limit";
			var saved:Journal = haxe.Json.parse(Fs.getContent(name));
			if (saved.version != 1 || saved.file != file || saved.base == null || saved.revisions == null || saved.revisions.length > MAX_ENTRIES) throw "Invalid local history";
			text = saved.base;
			var previous = saved.baseId;
			for (revision in saved.revisions) {
				if (revision.parent != previous || revision.id <= previous) throw "Broken local history chain";
				text = apply(text, revision); previous = revision.id;
			}
			data = saved;
		} catch (error:Dynamic) { text = disk; failed('Could not read local history for $file: $error'); }
		cached = {data:data, text:text, modified:false}; cache.set(file, cached);
		return cached;
	}

	/** Recover automatically only when the disk still matches the last known saved version. */
	public function recover(file:String, disk:String):String {
		var item = load(file, disk);
		var hash = Sha256.encode(disk);
		if (item.data.savedHash == hash) return item.text;
		if (item.text != disk) append(item, disk, "Disk version");
		item.data.savedHash = hash; item.data.undo = null; item.modified = true;
		return disk;
	}

	public function current(file:String, fallback:String):String return load(file, fallback).text;

	public function undo(file:String, text:String):Dynamic {
		var item = load(file, text);
		return item.text == text ? item.data.undo : null;
	}

	public function record(file:String, before:String, after:String, undo:Dynamic, kind = "Edit", ?author:String):Void {
		var item = load(file, before);
		if (item.text != before) append(item, before, "Disk version");
		if (kind == "Edit" && undo != null && item.data.undo != null) try {
			var previous:Dynamic = item.data.undo;
			if (undo.undo.length < previous.undo.length && undo.redo.length > previous.redo.length) kind = "Undo";
			else if (undo.redo.length < previous.redo.length && undo.undo.length > previous.undo.length
				&& haxe.Json.stringify(undo.undo[Std.int(undo.undo.length) - 1]) == haxe.Json.stringify(previous.redo[Std.int(previous.redo.length) - 1])) kind = "Redo";
		} catch (_:Dynamic) {}
		if (item.text != after) append(item, after, kind, author);
		item.data.undo = undo; item.modified = true;
		changed();
	}

	function append(item:Cached, next:String, kind:String, ?author:String):Void {
		var before = item.text, from = 0, suffix = 0;
		while (from < before.length && from < next.length && before.charCodeAt(from) == next.charCodeAt(from)) from++;
		while (suffix < before.length - from && suffix < next.length - from && before.charCodeAt(before.length - suffix - 1) == next.charCodeAt(next.length - suffix - 1)) suffix++;
		var rows = item.data.revisions, parent = rows.length == 0 ? item.data.baseId : rows[rows.length - 1].id;
		rows.push({id:parent + 1, parent:parent, time:Date.now().getTime(), kind:kind, from:from,
			removed:before.substring(from, before.length - suffix), inserted:next.substring(from, next.length - suffix), author:author});
		item.text = next; item.modified = true;
		while (rows.length > MAX_ENTRIES) trim(item);
	}

	function trim(item:Cached):Void {
		var first = item.data.revisions.shift();
		if (item.data.baseOwners == null && first.author == null) item.data.base = apply(item.data.base,first);
		else {
			var snapshot = LineOwners.patch({text:item.data.base, owners:item.data.baseOwners ?? []}, first);
			item.data.base = snapshot.text; item.data.baseOwners = snapshot.owners;
		}
		item.data.baseId = first.id; item.data.baseTime = first.time;
	}

	static function apply(text:String, revision:Revision):String {
		if (revision.from < 0 || revision.from > text.length || revision.removed == null || revision.inserted == null || text.substr(revision.from, revision.removed.length) != revision.removed) throw "Local history patch does not match its parent";
		return text.substr(0, revision.from) + revision.inserted + text.substr(revision.from + revision.removed.length);
	}

	public function saved(file:String, text:String, undo:Dynamic):Void {
		var item = load(file, text);
		record(file, text, text, undo);
		append(item, text, "Saved"); item.data.savedHash = Sha256.encode(text);
		flush(file); changed();
	}

	public function entries(file:String, disk:String):Array<HistoryEntry> {
		var item = load(file, disk), out:Array<HistoryEntry> = [{id:item.data.baseId, time:item.data.baseTime, kind:"Original"}];
		for (row in item.data.revisions) out.push({id:row.id, time:row.time, kind:row.kind, author:row.author});
		out.reverse(); return out;
	}

	public function revision(file:String, disk:String, id:Int):String {
		var item = load(file, disk), text = item.data.base;
		if (id == item.data.baseId) return text;
		for (row in item.data.revisions) { text = apply(text, row); if (row.id == id) return text; }
		throw "Local revision is no longer available";
	}

	/** A data-only copy for comparison workers; no worker reads the mutable journal cache. */
	public function snapshot(file:String, disk:String):HistoryJournal {
		var data = load(file,disk).data;
		return {base:data.base, baseId:data.baseId, owners:data.baseOwners == null ? [] : data.baseOwners.copy(),
			revisions:[for (row in data.revisions) {id:row.id,parent:row.parent,time:row.time,kind:row.kind,from:row.from,
				removed:row.removed,inserted:row.inserted,author:row.author}]};
	}

	/** Atomic replacement keeps a failed write from destroying the previous checkpoint. */
	public function flush(file:String):Void {
		var item = cache.get(file);
		if (item == null || !item.modified) return;
		try {
			var text = haxe.Json.stringify(item.data);
			while (haxe.io.Bytes.ofString(text).length > MAX_BYTES && item.data.revisions.length > 0) {
				trim(item); text = haxe.Json.stringify(item.data);
			}
			if (haxe.io.Bytes.ofString(text).length > MAX_BYTES) throw "Local history exceeds the per-file size limit";
			Fs.createDirectory(directory);
			var name = path(file); Fs.saveContent(name + ".tmp", text); Fs.rename(name + ".tmp", name);
			item.modified = false;
		} catch (error:Dynamic) failed('Could not checkpoint local history for $file: $error');
	}

	/** A renamed file keeps its journal, including when its editor has already been released. */
	public function move(from:String, to:String):Void {
		var names = files();
		if (Fs.exists(directory)) for (name in Fs.readDirectory(directory)) if (StringTools.endsWith(name, ".json")) try {
			var data:Dynamic = haxe.Json.parse(Fs.getContent(directory + "/" + name));
			if (data.version == 1 && Std.isOfType(data.file, String) && names.indexOf(data.file) < 0) names.push(data.file);
		} catch (_:Dynamic) {}
		for (file in names) if (file == from || StringTools.startsWith(file, haxe.io.Path.addTrailingSlash(from))) {
			var next = to + file.substr(from.length), item = load(file, "");
			item.data.file = next; item.modified = true;
			cache.set(next, item); flush(next);
			if (!item.modified) {
				cache.remove(file);
				if (Fs.exists(path(file))) Fs.deleteFile(path(file));
			}
		}
	}

	public function forget(file:String):Void { flush(file); cache.remove(file); }
	public function dispose():Void { for (file in files()) flush(file); cache.clear(); }
}
