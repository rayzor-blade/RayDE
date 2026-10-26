package rayde.ui;

import rayde.workspace.Fs;
import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Select;
import ashui.components.ToggleSwitch;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.build.HxmlFile;
import rayde.ui.BuildLookup.BuildLookupRequest;
import rayde.ui.BuildLookup.BuildLookupResult;

using StringTools;

typedef BuildSettingsProps = {
	file:HxmlFile,
	/** The project's folder, which the build's paths are relative to. */
	root:String,
	/** Called after each change has been written to the build file. */
	onChanged:Void->Void
};

/**
 * The build file as a form: the target, the main class, the source folders,
 * the libraries, the defines and the compiler's switches, each written to the
 * file as soon as it is changed, with its comments and any argument the form
 * does not know left where they are. Arguments the form does not manage are
 * listed at the end, so nothing in the file is out of sight.
 */
class BuildSettings extends Component<BuildSettingsProps> {
	static final targetLabels = [
		"hl" => "HashLink (--hl)", "js" => "JavaScript (--js)", "cpp" => "C++ (--cpp)", "neko" => "Neko (--neko)", "lua" => "Lua (--lua)", "php" => "PHP (--php)",
		"python" => "Python (--python)", "jvm" => "JVM (--jvm)", "swf" => "Flash (--swf)", "interp" => "Interpreter (--interp), no output"
	];
	static final commonDefines = ["analyzer-optimize", "no-deprecation-warnings", "real-position", "source-map-content"];

	final revision = Signal.make(0);
	final mainClass = Signal.make("");
	final output = Signal.make("");
	final newFolder = Signal.make("");
	final newKey = Signal.make("");
	final newValue = Signal.make("");
	final lookup = Signal.make((null:Null<BuildLookupResult>));
	final lookupError = Signal.make("");
	final lookupWorker = new rayde.run.Worker<BuildLookupRequest,BuildLookupResult>(BuildLookup.scan,ashui.core.Work.notify);

	function render():Element {
		mainClass.set(props.file.value("--main") == null ? "" : props.file.value("--main"));
		var t = props.file.target();
		output.set(t == null || t.output == null ? "" : t.output);
		new ashui.reactive.Watch(() -> { revision.get(); {root:props.root,paths:props.file.values("-cp"),main:mainClass.get().trim()}; }, request -> {
			lookup.set(null); lookupError.set(""); lookupWorker.submit("paths",request);
		}, (a,b) -> a.root == b.root && a.main == b.main && a.paths.join("\n") == b.paths.join("\n"));
		var receive:ashui.layout.LayoutTree->Void = tree -> {
			if (tree != this.tree) return;
			for (result in lookupWorker.poll()) if (result.error != null) lookupError.set(result.error); else if (result.value != null) lookup.set(result.value);
		};
		ashui.layout.LayoutTree.flushHooks.push(receive);
		ashui.reactive.Owner.onCleanup(() -> { lookupWorker.dispose(); ashui.layout.LayoutTree.flushHooks.remove(receive); });
		return <div id="rayde-build" class="rayde-settings flex flex-1 min-h-0 justify-center overflow-auto">
			<div class="flex flex-col gap-6 px-8 py-8" width={780}>
				${SettingsParts.header(Icons.HAMMER_LINE, "Build", haxe.io.Path.withoutDirectory(props.file.path) + ". Each change is written to the file at once.")}
				<if {props.file.multiple()}>
					<div class="rayde-note flex items-center gap-3 px-4 py-3"><icon document={Icons.INFORMATION_LINE} class="size-4 shrink-0"/><text class="text-xs">This file holds several builds separated by --next. The form edits the first one.</text></div>
				</if>
				<for {r in [revision.get()]}>${sections(r)}</for>
				<div class="shrink-0" height={40}/>
			</div>
		</div>;
	}

	/** Writes `edit` to the file, shows the result, and tells the workbench. */
	function change(edit:Void->Void):Void {
		edit();
		props.file.save();
		revision.set(revision.get() + 1);
		props.onChanged();
	}

	function sections(_:Int):Element
		return <div class="flex flex-col gap-6">
			${section("rayde-build-target-section", "Target", "The compiler backend. With none set, RayDE compiles to HashLink and runs it on ash.", targetFields())}
			${section("rayde-build-entry-section", "Main", "The class whose static main() runs first (--main).", entryFields())}
			${section("rayde-build-folders-section", "Class path", "Directories searched, in order, when resolving imports (-cp).", folderFields())}
			${section("rayde-build-defines-section", "Define", "Compile-time flags for #if conditionals (-D name or name=value).", defineFields())}
			${section("rayde-build-compiler-section", "Compiler", "Flags passed to every compile.", compilerFields())}
			<if {props.file.others().length > 0}>${section("rayde-build-other-section", "Other arguments", "Arguments the form does not manage, such as --macro and -w. They stay in the file as written.", otherFields())}</if>
		</div>;

	function section(id:String, title:String, description:String, content:Array<Element>):Element
		return SettingsParts.card(id, title, description, content);

	function field(label:String, hint:String, control:Element):Element
		return SettingsParts.field(label, hint, control);

	// Target

	function targetFields():Array<Element> {
		var t = props.file.target();
		var items:Array<Element> = [<select-item value="">None, RayDE adds --hl</select-item>];
		for (kind in HxmlFile.targets)
			items.push(<select-item value={kind}>${targetLabels.get(kind)}</select-item>);
		var out:Array<Element> = [
			field("Backend", "The compiler target (--hl, --js, --cpp, ...)", <select id="rayde-build-target" value={t == null ? "" : t.kind} size={Sm} class="rayde-control" onChange={kind -> change(() -> setTarget(kind))}>{items}</select>)
		];
		if (t != null && t.kind != "interp")
			out.push(field("File", "Output path from the project root",
				<input height={32} id="rayde-build-output" value={output} placeholder="bin/app" class="rayde-control" onKeyDown={e -> if (e.key.match(Named(Enter))) commitOutput()}/>));
		return out;
	}

	function setTarget(kind:String):Void {
		if (kind == "") {
			for (k in HxmlFile.targets)
				props.file.set("--" + k, null);
			return;
		}
		var t = props.file.target(), keep = t == null ? null : t.output;
		props.file.setTarget(kind, kind == "interp" ? null : keep == null || keep == "" ? "bin/app." + extension(kind) : keep);
	}

	static function extension(kind:String):String
		return switch kind {
			case "hl": "hl";
			case "js": "js";
			case "swf": "swf";
			case "jvm": "jar";
			case "neko": "n";
			case "python": "py";
			case "lua": "lua";
			case _: "out";
		}

	function commitOutput():Void {
		var t = props.file.target(), value = output.get().trim();
		if (t == null || value == (t.output == null ? "" : t.output))
			return;
		change(() -> props.file.setTarget(t.kind, value == "" ? null : value));
	}

	// Entry point

	function entryFields():Array<Element> {
		return [
			field("Class", "Fully qualified, such as app.Main",
				<input height={32} id="rayde-build-main" value={mainClass} placeholder="Main" class="rayde-control" onKeyDown={e -> if (e.key.match(Named(Enter))) commitMain()}/>),
			<for {result in [lookup.get()]}><if {mainClass.get().trim() != ""}>
				<if {result == null}><text class="text-xs text-text-tertiary">${lookupError.get() == "" ? "Checking class paths…" : "Class paths could not be checked."}</text>
				<else><if {result.found != null}><div class="flex items-center gap-2"><icon document={Icons.CHECK_LINE} class="size-4 text-success"/><text id="rayde-build-main-found" class="text-xs text-text-secondary">${relative(result.found)}</text></div>
				<else><div class="flex items-center gap-2"><icon document={Icons.ERROR_WARNING_LINE} class="size-4 text-warning"/><text id="rayde-build-main-missing" class="text-xs text-warning">${"No " + result.main.split(".").join("/") + ".hx on the class paths"}</text></div></if></if>
			</if></for>
		];
	}

	function commitMain():Void {
		var value = mainClass.get().trim();
		if (value == (props.file.value("--main") == null ? "" : props.file.value("--main")))
			return;
		change(() -> props.file.set("--main", value == "" ? null : value));
	}

	function relative(path:String):String {
		var root = haxe.io.Path.addTrailingSlash(props.root);
		return path.startsWith(root) ? path.substr(root.length) : path;
	}

	// Source folders

	function folderFields():Array<Element> {
		var cps = props.file.values("-cp");
		var out:Array<Element> = [<for {result in [lookup.get()]}><div class="flex flex-col gap-2">{[for (cp in cps) row(Icons.FOLDER_LINE, cp, result == null ? lookupError.get() == "" ? "Checking…" : "Unavailable" : result.folders.get(cp) == true ? null : "Not found", () -> change(() -> props.file.remove("-cp", cp)))]}</div></for>];
		if (cps.length == 0)
			out.push(<text class="text-xs text-text-tertiary">No class paths. The compiler searches only the working directory.</text>);
		out.push(adder(newFolder, "Add a class path", "rayde-build-folder", () -> addFolder(newFolder.get())));
		out.push(<for {result in [lookup.get()]}><if {result != null && result.suggestions.length > 0}>${chips("Detected", [for (s in result.suggestions) {label:s,run:() -> addFolder(s)}])}</if></for>);
		return out;
	}

	function addFolder(path:String):Void {
		var value = path.trim();
		if (value == "")
			return;
		newFolder.set("");
		change(() -> props.file.add("-cp", value));
	}

	// Defines

	function defineFields():Array<Element> {
		var defines = props.file.values("-D");
		var out:Array<Element> = [for (d in defines) row(Icons.FLAG_LINE, d, null, () -> change(() -> props.file.remove("-D", d)))];
		if (defines.length == 0)
			out.push(<text class="text-xs text-text-tertiary">No defines.</text>);
		out.push(<div class="flex items-center gap-2">
			<input height={32} id="rayde-build-define" value={newKey} placeholder="Name" class="rayde-control" onKeyDown={e -> if (e.key.match(Named(Enter))) addDefine()}/>
			<input height={32} id="rayde-build-define-value" value={newValue} placeholder="Value (optional)" class="rayde-control-narrow" onKeyDown={e -> if (e.key.match(Named(Enter))) addDefine()}/>
			<button id="rayde-build-define-add" variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> addDefine()}>Add</button>
		</div>);
		var suggestions = [for (d in commonDefines) if (!Lambda.exists(defines, x -> x == d || x.startsWith(d + "="))) d];
		if (suggestions.length > 0)
			out.push(chips("Common", [for (s in suggestions) {label: s, run: () -> change(() -> props.file.add("-D", s))}]));
		return out;
	}

	function addDefine():Void {
		var key = newKey.get().trim(), value = newValue.get().trim();
		if (key == "")
			return;
		newKey.set("");
		newValue.set("");
		change(() -> props.file.add("-D", value == "" ? key : key + "=" + value));
	}

	// Compiler

	function compilerFields():Array<Element> {
		var dce = props.file.value("--dce");
		return [
			field("Debug", "Emit debug symbols and positions (--debug)", <toggle-switch id="rayde-build-debug" checked={props.file.has("--debug")} size={Sm} onChange={on -> change(() -> props.file.setSwitch("--debug", on))}/>),
			field("No traces", "Strip trace() calls (--no-traces)", <toggle-switch id="rayde-build-no-traces" checked={props.file.has("--no-traces")} size={Sm} onChange={on -> change(() -> props.file.setSwitch("--no-traces", on))}/>),
			field("No inline", "Keep inline functions as calls, for stepping (--no-inline)", <toggle-switch id="rayde-build-no-inline" checked={props.file.has("--no-inline")} size={Sm} onChange={on -> change(() -> props.file.setSwitch("--no-inline", on))}/>),
			field("Dead code elimination", "What the compiler drops from the output (--dce)",
				<select id="rayde-build-dce" value={dce == null ? "" : dce} size={Sm} class="rayde-control" onChange={v -> change(() -> props.file.set("--dce", v == "" ? null : v))}>
					<select-item value="">std, the standard library only (default)</select-item>
					<select-item value="full">full, everything unused</select-item>
					<select-item value="no">no, keep everything</select-item>
				</select>)
		];
	}

	// Other arguments

	function otherFields():Array<Element>
		return [for (o in props.file.others()) row(Icons.CODE_BOX_LINE, o.text, null, () -> change(() -> props.file.removeLine(o.index)))];

	// Pieces

	/** A line of a list: an icon, what it is, a note when something is wrong, and a button that removes it. */
	function row(icon:ashui.svg.SvgDocument, text:String, warning:Null<String>, remove:Void->Void):Element
		return <div class="rayde-setting-row flex items-center gap-3 px-3" height={40}>
			<icon document={icon} class="size-4 shrink-0 text-text-secondary"/>
			<text class="rayde-mono text-sm flex-1 min-w-0">${text}</text>
			<if {warning != null}><text class="text-xs text-warning">${warning}</text></if>
			<tooltip label="Remove"><button variant={Ghost} size={Icon} class="rayde-remove" onClick={_ -> remove()}><icon document={Icons.CLOSE_LINE} class="size-4"/></button></tooltip>
		</div>;

	/** An input and the button that adds what is typed in it. */
	function adder(value:Signal<String>, placeholder:String, id:String, add:Void->Void):Element
		return <div class="flex items-center gap-2">
			<input height={32} id={id} value={value} placeholder={placeholder} class="rayde-control-wide" onKeyDown={e -> if (e.key.match(Named(Enter))) add()}/>
			<button id={id + "-add"} variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> add()}>Add</button>
		</div>;

	/** A line of suggestions, each a button that adds itself. */
	function chips(title:String, items:Array<{label:String, run:Void->Void}>):Element
		return <div class="flex items-center gap-2 flex-wrap">
			<text class="text-xs text-text-tertiary">${title}</text>
			{[for (i in items) chip(i.label, i.run)]}
		</div>;

	function chip(label:String, run:Void->Void):Element
		return <button variant={Outline} size={Sm} class="rayde-chip" onClick={_ -> run()}><icon document={Icons.ADD_LINE} class="size-3.5"/>${label}</button>;
}
