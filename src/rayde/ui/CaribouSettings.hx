package rayde.ui;

import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Select;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.build.RayzorFile;

using StringTools;

typedef CaribouSettingsProps = {
	path:String,
	/** What Caribou says is wrong with the file, asked again after each change. */
	problems:Void->Array<String>,
	onChanged:Void->Void,
	onEditText:Void->Void,
	beforeChange:Void->Void
};

/** A Caribou `.cbproj` as a form; each control edits only its own field and the rest of the file stays as written. */
class CaribouSettings extends Component<CaribouSettingsProps> {
	/** The languages a project can hold modules in. */
	static final LANGUAGES = ["haxe", "lua", "python", "wren"];

	var file:Null<RayzorFile>;
	final revision = Signal.make(0);
	final error = Signal.make("");

	function render():Element {
		load();
		return SettingsParts.page("rayde-caribou-build", <div class="flex flex-col gap-6">
			${SettingsParts.header(Icons.HAMMER_LINE, "Build", haxe.io.Path.withoutDirectory(props.path) + ". Press Enter to save text fields; other changes save immediately.")}
			<div class="flex items-center gap-3">
				<button id="rayde-caribou-edit-text" variant={Outline} size={Sm} onClick={_ -> props.onEditText()}><icon document={Icons.CODE_S_SLASH_LINE} class="size-4"/>Edit as Text</button>
				<button id="rayde-caribou-reload" variant={Ghost} size={Sm} onClick={_ -> { load(); revision.set(revision.get() + 1); }}>Reload</button>
			</div>
			<if {error.get() != ""}><text id="rayde-caribou-error" class="text-sm text-error">${error.get()}</text></if>
			<for {r in [revision.get()]}>${sections(r)}</for>
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
			var cards:Array<Element> = [], problems = props.problems();
			if (problems.length > 0) cards.push(card("problems", "Problems", "What Caribou rejects or ignores in this file.", [for (p in problems) <text class="rayde-mono text-sm text-warning">${p}</text>]));
			if (file.workspace()) {
				cards.push(card("workspace", "Workspace", "Member project directories, relative to this file. Open a member to run it.", list(["workspace", "members"], "Member directory")));
			} else {
				cards.push(card("project", "Project", "Identity and entry point.", [
					textField(["project", "name"], "Name", "Project name", "game"),
					textField(["project", "entry"], "Entry point", "language:module, such as haxe:game.Main", "haxe:Main")
				]));
				cards.push(card("languages", "Languages", "The languages the project's modules are written in. Modules are found under the source roots.", languages()));
				cards.push(card("paths", "Haxe class paths", "Extra class paths, relative to this file. The source roots are always compiled whole; these only as far as the program reaches.", list(["haxe", "class-paths"], "Class path")));
				cards.push(card("defines", "Haxe defines", "Compile-time flags. An empty value creates a boolean flag; a supplied value is a string.", defines()));
				cards.push(card("run", "Run", "Used by Run when this Caribou reads a [run] table.", [
					textField(["run", "preset"], "Preset", "The runtime preset: game, application and so on", "application")
				].concat(list(["run", "args"], "Argument"))));
			}
			cards.push(<text class="text-xs text-text-secondary">Use Edit as Text for dependencies, plugins and other TOML fields.</text>);
			return <div class="flex flex-col gap-6">{cards}</div>;
		} catch (e:Dynamic) { error.set(Std.string(e)); return <div/>; }
	}

	static function id(path:Array<String>):String return "rayde-caribou-" + path.join("-");
	function card(key:String, title:String, hint:String, fields:Array<Element>):Element
		return SettingsParts.card("rayde-caribou-" + key + "-section", title, hint, fields);

	function textField(path:Array<String>, label:String, hint:String, placeholder:String):Element {
		var text = Signal.make(file.text(path));
		return SettingsParts.field(label, hint, <input id={id(path)} height={32} value={text} placeholder={placeholder} class="rayde-control" onKeyDown={e -> {
			if (e.key.match(Named(Enter)) && text.get().trim() != file.text(path)) change(() -> {
				var value = text.get().trim();
				if (path.join(".") == "project.entry" && value != "" && !~/^[A-Za-z0-9_]+:\S+$/.match(value)) throw "The entry point is language:module, such as haxe:game.Main.";
				file.set(path, value == "" ? null : value);
			});
		}}/>);
	}

	/** A switch for each language: on adds it to the list, off takes it out. */
	function languages():Array<Element> {
		var chosen = file.strings(["project", "languages"]), out:Array<Element> = [];
		for (language in LANGUAGES) {
			var name = language, on = chosen.indexOf(name) >= 0;
			out.push(SettingsParts.field(name.charAt(0).toUpperCase() + name.substr(1), on ? "Modules in " + name + " are found and loaded" : "Not part of this project", <select id={"rayde-caribou-language-" + name} value={on ? "true" : "false"} size={Sm} class="rayde-control" onChange={v -> change(() -> {
				file.reload();
				var now = file.strings(["project", "languages"]), at = now.indexOf(name);
				if (v == "true" && at < 0) file.append(["project", "languages"], name);
				else if (v != "true" && at >= 0) file.removeAt(["project", "languages"], at);
			})}>
				<select-item value="true">Enabled</select-item><select-item value="false">Disabled</select-item>
			</select>));
		}
		return out;
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
		var out:Array<Element> = [], table:Dynamic = file.value(["haxe", "defines"]);
		if (table != null) {
			var names = Reflect.fields(table); names.sort(Reflect.compare);
			for (key in names) out.push(row(key + " = " + Std.string(Reflect.field(table, key)), () -> file.set(["haxe", "defines", key], null)));
		}
		var name = Signal.make(""), value = Signal.make("");
		function add():Void { if (name.get().trim() != "") change(() -> file.set(["haxe", "defines", name.get().trim()], value.get() == "" ? (true:Dynamic) : value.get())); }
		out.push(<div class="flex items-center gap-2">
			<input id="rayde-caribou-define-name" height={32} value={name} placeholder="Name" class="rayde-control" onKeyDown={e -> if (e.key.match(Named(Enter))) add()}/>
			<input id="rayde-caribou-define-value" height={32} value={value} placeholder="Value (optional)" class="rayde-control-narrow" onKeyDown={e -> if (e.key.match(Named(Enter))) add()}/>
			<button id="rayde-caribou-define-add" variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> add()}>Add</button>
		</div>);
		return out;
	}

	function row(label:String, remove:Void->Void):Element
		return <div class="rayde-setting-row flex items-center gap-3 px-3" height={40}>
			<text class="rayde-mono text-sm flex-1 min-w-0">${label}</text>
			<tooltip label="Remove"><button variant={Ghost} size={Icon} class="rayde-remove" onClick={_ -> change(remove)}><icon document={Icons.CLOSE_LINE} class="size-4"/></button></tooltip>
		</div>;
}
