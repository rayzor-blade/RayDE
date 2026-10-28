package rayde.project;

import rayde.workspace.Fs;
import rayde.ext.Manifest;
import rayde.project.ProjectTemplates.ProjectTemplate;

/** Extension-owned data only; registered starters never retain a VM, editor or view. */
class ProjectStarters {
	final entries = new Map<String, ProjectTemplate>();
	public var onChanged:Null<Void->Void>;
	public function new() {}

	public function list():Array<ProjectTemplate> {
		var items = [for (item in entries) item];
		items.sort((a, b) -> Reflect.compare(a.name, b.name));
		return items;
	}

	public function register(owner:String, manifest:Manifest, data:Dynamic):String {
		if (manifest == null || data == null) throw "A project starter requires a manifest and definition";
		var local = text(data, "id", null, 64);
		if (!~/^[A-Za-z][A-Za-z0-9_.-]*$/.match(local)) throw "A starter id needs letters, digits, underscores, dots or hyphens";
		var id = key(manifest, local), category = text(data, "category", "Applications", 32);
		var previous = entries.get(id);
		if (previous != null && previous.owner != owner) throw "That starter id belongs to another extension host";
		if (["Applications", "Games", "Libraries"].indexOf(category) < 0) throw "Starter category must be Applications, Games or Libraries";
		if (!Std.isOfType(data.files, Array)) throw "Starter files must be an array of {path, text} objects";
		if ((data.files:Array<Dynamic>).length == 0 || (data.files:Array<Dynamic>).length > 256) throw "A starter needs between 1 and 256 files";
		var files = new Map<String, String>();
		for (file in (data.files:Array<Dynamic>)) {
			var path = text(file, "path", null, 240);
			if (files.exists(path)) throw "Starter file paths must be unique";
			files.set(path, text(file, "text", null, 1024 * 1024, true));
		}
		var scaffold = {entry:text(data, "entry", "", 240, true), files:files};
		if (data.runner != null) ProjectRunner.configure(files, text(data, "runner", null, 20));
        if(data.run!=null)rayde.run.RunConfigurations.install(files,data.run);
		ProjectTemplates.validate(scaffold);
		var icon = text(data, "icon", "code", 240), iconPath:Null<String> = null;
		if (StringTools.endsWith(icon.toLowerCase(), ".svg")) {
			if (!ProjectTemplates.relativePath(icon)) throw "Starter icon must be relative to its extension";
			var full = Fs.fullPath(haxe.io.Path.join([manifest.root, icon]));
			var root = haxe.io.Path.addTrailingSlash(Fs.fullPath(manifest.root));
			if (!StringTools.startsWith(full, root) || Fs.isDirectory(full) || Fs.stat(full).size > 64 * 1024) throw "Starter icon must be an SVG within the extension, at most 64 KiB";
			iconPath = full;
		}
		var item:ProjectTemplate = {
			id:id, owner:owner, name:text(data, "name", null, 80), category:category,
			description:text(data, "description", "", 200, true), target:text(data, "target", "Cross-platform", 40),
			requirements:text(data, "requirements", "See the project's README", 300), command:text(data, "command", "See the project's README", 300),
			docs:text(data, "docs", "", 500, true), icon:icon, iconPath:iconPath, scaffold:scaffold,run:data.run
		};
		var own = 1, count = 1, size = weight(item);
		for (other in entries) if (other.id != id) {
			count++; size += weight(other); if (other.owner == owner) own++;
		}
		if (own > 16 || count > 64 || size > 8 * 1024 * 1024) throw "Starter catalog exceeds 16 per extension, 64 total or 8 MiB of text";
		entries.set(id, item); changed();
		return id;
	}

	public function unregister(owner:String, manifest:Manifest, id:String):Void {
		var item = entries.get(id) ?? entries.get(key(manifest, id));
		if (item != null && item.owner == owner) { entries.remove(item.id); changed(); }
	}

	public function release(owner:String):Void {
		var removed = false;
		for (item in list()) if (item.owner == owner) { entries.remove(item.id); removed = true; }
		if (removed) changed();
	}

	static function key(manifest:Manifest, local:String):String return 'ext:${manifest.id}:$local';
	static function weight(item:ProjectTemplate):Int {
		var size = 0;
		for (text in item.scaffold.files) size += haxe.io.Bytes.ofString(text).length;
		return size;
	}
	function changed():Void { if (onChanged != null) onChanged(); }
	static function text(data:Dynamic, field:String, fallback:Null<String>, limit:Int, empty = false):String {
		var value:Dynamic = data == null ? null : Reflect.field(data, field);
		if (value == null && fallback != null) return fallback;
		if (!Std.isOfType(value, String) || !empty && StringTools.trim(value) == "" || (value:String).length > limit) throw 'Starter $field must be text, at most $limit characters';
		return value;
	}
}
