package rayde.ui;

import rayde.workspace.Fs;
import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Select;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.build.RayzorFile;

using StringTools;

typedef RayzorSettingsProps = {
	path:String,
	onChanged:Void->Void,
	onEditText:Void->Void,
	beforeChange:Void->Void,
    ?onRunChanged:Void->Void
};

/** The active Rayzor manifest as a form; each control edits only its own field. */
class RayzorSettings extends Component<RayzorSettingsProps> {
	var file:Null<RayzorFile>;
	final revision = Signal.make(0);
	final error = Signal.make("");

	function render():Element {
		load();
		return SettingsParts.page("rayde-rayzor-build", <div class="flex flex-col gap-6">
			${SettingsParts.header(Icons.HAMMER_LINE, "Build", "rayzor.toml. Press Enter to save text fields; other changes save immediately.")}
			<div class="flex items-center gap-3">
				<button id="rayde-rayzor-edit-text" variant={Outline} size={Sm} onClick={_ -> props.onEditText()}><icon document={Icons.CODE_S_SLASH_LINE} class="size-4"/>Edit as Text</button>
				<button id="rayde-rayzor-reload" variant={Ghost} size={Sm} onClick={_ -> { load(); revision.set(revision.get() + 1); }}>Reload</button>
			</div>
			<if {error.get() != ""}><text id="rayde-rayzor-error" class="text-sm text-error">${error.get()}</text></if>
			<for {r in [revision.get()]}>${sections(r)}</for>
            <run-configuration-settings root={haxe.io.Path.directory(props.path)} family="rayzor" onChanged={props.onRunChanged}/>
		</div>);
	}

	function load():Void {
		try { file = new RayzorFile(props.path); error.set(""); }
		catch (e:Dynamic) { file = null; error.set(Std.string(e)); }
	}

	function change(edit:Void->Void):Void {
		try {
			props.beforeChange();
			edit();
			error.set("");
			props.onChanged();
			revision.set(revision.get() + 1);
		} catch (e:Dynamic) { error.set(Std.string(e)); }
	}

	function sections(_:Int):Element {
		if (file == null) return <div/>;
		try {
			var cards:Array<Element> = [];
			if (file.workspace()) {
				cards.push(card("workspace", "Workspace", "Member project directories, relative to this manifest.", list(["workspace", "members"], "Member directory")));
				cards.push(card("cache", "Shared cache", "Shared cache configuration stored for Rayzor workspace loaders.", [
					textField(["workspace", "cache", "dir"], "Directory", "Relative to the workspace root", ".rayzor/cache")
				]));
			} else {
				cards.push(card("project", "Project", "Project identity and entry point.", [
					textField(["project", "name"], "Name", "Project name", "my-app"),
					textField(["project", "version"], "Version", "Project version", "0.1.0"),
					textField(["project", "entry"], "Entry point", "Source file for rayzor run; omit for a library", "src/Main.hx"),
					textField(["project", "hxml"], "Build HXML", "rayzor build delegates to this file; Run still needs an entry point", "build.hxml")
				]));
				cards.push(card("target", "Build", "Output is used by rayzor build, bundle and AOT. The current CLI does not apply the stored target, optimization or preset fields.", [
					textField(["build", "target"], "Stored target", "Target selection currently uses CLI flags", ""),
					textField(["build", "output"], "Output", "Output path, relative to the project root", "build/my-app"),
					choice(["build", "opt-level"], "Stored optimization", "Manifest optimization value", "2 (manifest default)", ["0", "1", "2", "3"], true),
					choice(["build", "preset"], "Stored preset", "Run uses CLI --preset or the [tier] table", "application (manifest default)", ["script", "application", "server", "benchmark", "development", "embedded"])
				]));
				if (file.text(["project", "hxml"]) != "") cards.push(<text class="text-xs text-text-secondary">HXML configures rayzor build and RayDE's Haxe editor fallback. Native Run still reads the entry point and manifest class paths.</text>);
				cards.push(card("paths", "Class paths", "Source directories searched in declaration order, relative to the manifest. Omitted class paths add no source directories.", list(["build", "class-paths"], "Source directory")));
				cards.push(card("defines", "Defines", "Compile-time flags. An empty value creates a boolean flag; a supplied value is a string.", defines()));
				cards.push(card("cache", "Stored cache options", "The current CLI uses --no-cache and --cache-dir instead of these manifest values.", [
					boolean(["cache", "enabled"], "Enabled", "Reuse cached compilation data", true),
					textField(["cache", "dir"], "Directory", "Relative to the project root", ".rayzor/cache")
				]));
				cards.push(card("native-libs", "Native libraries", "Dynamic library paths relative to the project root.", list(["build", "native-libs"], "Library path")));
				cards.push(card("resources", "Resources", "Resources to embed: file@name, or a file path used as its name.", list(["build", "resources"], "assets/file@name")));
				cards.push(card("bundle", "Stored bundle options", "The current bundle command uses --strip and --no-compress instead of these manifest values.", [
					boolean(["bundle", "compress"], "Compression", "Compress with zstd", null),
					boolean(["bundle", "strip"], "Tree shaking", "Remove unused code", null)
				]));
			}
			cards.push(<text class="text-xs text-text-secondary">Use Edit as Text for dependencies, WebAssembly hosts, custom tier settings and other TOML fields.</text>);
			return <div class="flex flex-col gap-6">{cards}</div>;
		} catch (e:Dynamic) { error.set(Std.string(e)); return <div/>; }
	}

	static function id(path:Array<String>):String return "rayde-rayzor-" + path.join("-");
	function card(key:String, title:String, hint:String, fields:Array<Element>):Element
		return SettingsParts.card("rayde-rayzor-" + key + "-section", title, hint, fields);

	function textField(path:Array<String>, label:String, hint:String, placeholder:String):Element {
		var text = Signal.make(file.text(path));
		return SettingsParts.field(label, hint, <input id={id(path)} height={32} value={text} placeholder={placeholder} class="rayde-control" onKeyDown={e -> {
			if (e.key.match(Named(Enter)) && text.get().trim() != file.text(path)) change(() -> {
				var value = text.get().trim();
				if (path.join(".") == "project.hxml" && value != "") {
					var full = haxe.io.Path.isAbsolute(value) ? value : haxe.io.Path.join([haxe.io.Path.directory(props.path), value]);
					if (!Fs.exists(full) || Fs.isDirectory(full)) throw "HXML file not found: " + value;
				}
				file.set(path, value == "" ? null : value);
			});
		}}/>);
	}

	function choice(path:Array<String>, label:String, hint:String, defaultLabel:String, values:Array<String>, number = false):Element {
		var current = file.text(path), options = values.copy();
		if (current != "" && options.indexOf(current) < 0) options.push(current);
		var items:Array<Element> = [<select-item value="">${defaultLabel}</select-item>];
		for (v in options) items.push(<select-item value={v}>${v}</select-item>);
		return SettingsParts.field(label, hint, <select id={id(path)} value={current} size={Sm} class="rayde-control" onChange={v -> change(() -> file.set(path, v == "" ? null : number ? (Std.parseInt(v):Dynamic) : v))}>{items}</select>);
	}

	function boolean(path:Array<String>, label:String, hint:String, defaultValue:Null<Bool>):Element {
		var current = file.text(path), inherited = defaultValue == null ? "Rayzor default" : (defaultValue ? "Enabled" : "Disabled") + " (default)";
		return SettingsParts.field(label, hint, <select id={id(path)} value={current} size={Sm} class="rayde-control" onChange={v -> change(() -> file.set(path, v == "" ? null : (v == "true":Dynamic)))}>
			<select-item value="">${inherited}</select-item><select-item value="true">Enabled</select-item><select-item value="false">Disabled</select-item>
		</select>);
	}

	function list(path:Array<String>, placeholder:String):Array<Element> {
		var entries = file.strings(path), out:Array<Element> = [];
		for (i in 0...entries.length) {
			var index = i, expected = entries[i];
			out.push(row(expected, () -> {
				file.reload();
				if (file.strings(path)[index] != expected) throw "The list changed on disk. Reload before removing this entry.";
				file.removeAt(path, index);
			}));
		}
		var value = Signal.make("");
		function add():Void { if (value.get().trim() != "") change(() -> file.append(path, value.get().trim())); }
		out.push(<div class="flex items-center gap-2"><input id={id(path) + "-new"} height={32} value={value} placeholder={placeholder} class="rayde-control-wide" onKeyDown={e -> if (e.key.match(Named(Enter))) add()}/><button id={id(path) + "-add"} variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> add()}>Add</button></div>);
		return out;
	}

	function defines():Array<Element> {
		var out:Array<Element> = [], table:Dynamic = file.value(["build", "defines"]);
		if (table != null) {
			var names = Reflect.fields(table); names.sort(Reflect.compare);
			for (key in names) out.push(row(key + " = " + Std.string(Reflect.field(table, key)), () -> file.set(["build", "defines", key], null)));
		}
		var name = Signal.make(""), value = Signal.make("");
		function add():Void { if (name.get().trim() != "") change(() -> file.set(["build", "defines", name.get().trim()], value.get() == "" ? (true:Dynamic) : value.get())); }
		out.push(<div class="flex items-center gap-2">
			<input id="rayde-rayzor-define-name" height={32} value={name} placeholder="Name" class="rayde-control" onKeyDown={e -> if (e.key.match(Named(Enter))) add()}/>
			<input id="rayde-rayzor-define-value" height={32} value={value} placeholder="Value (optional)" class="rayde-control-narrow" onKeyDown={e -> if (e.key.match(Named(Enter))) add()}/>
			<button id="rayde-rayzor-define-add" variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> add()}>Add</button>
		</div>);
		return out;
	}

	function row(label:String, remove:Void->Void):Element
		return <div class="rayde-setting-row flex items-center gap-3 px-3" height={40}>
			<text class="rayde-mono text-sm flex-1 min-w-0">${label}</text>
			<tooltip label="Remove"><button variant={Ghost} size={Icon} class="rayde-remove" onClick={_ -> change(remove)}><icon document={Icons.CLOSE_LINE} class="size-4"/></button></tooltip>
		</div>;
}
