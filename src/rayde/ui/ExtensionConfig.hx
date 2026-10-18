package rayde.ui;

import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Select;
import ashui.components.ToggleSwitch;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.ext.Manifest;

using StringTools;

typedef ExtensionConfigProps = {
	/** The extension's config as it is now; the page reads the file again after each change. */
	manifest:Manifest,
	/** Called after a change has been written, with the config read again. */
	onChanged:Manifest->Void,
	/** Opens the config file as text. */
	onEditText:Void->Void
};

/**
 * An extension's `.rayext` as a form: its name, its scripts, how its view shows itself (title, icon, where in the
 * layout, the tools of its header) and what it may do, each written to the file as soon as it is changed. What the
 * form does not know stays in the file as written.
 */
class ExtensionConfig extends Component<ExtensionConfigProps> {
	/** What an extension can ask to do, and what each lets it do. */
	static final capabilities = [
		{id: "workspace.read", label: "Workspace read", hint: "Read files and folders in the project"},
		{id: "workspace.write", label: "Workspace write", hint: "Create, modify and delete files"},
		{id: "process.spawn", label: "Process spawn", hint: "Start processes from an allow-list"},
		{id: "net.fetch", label: "Network fetch", hint: "HTTP requests to allow-listed hosts"},
		{id: "terminal", label: "Terminal", hint: "Open terminals and write to them"},
		{id: "clipboard", label: "Clipboard", hint: "Read and write the system clipboard"}
	];

	static final locations = [
		{id: "sidebar", label: "Sidebar (replaces the Explorer)"},
		{id: "secondary", label: "Secondary side bar (right)"},
		{id: "panel", label: "Panel tab (bottom)"},
		{id: "editor", label: "Editor tab"}
	];

	var m:Manifest;
	final revision = Signal.make(0);
	final name = Signal.make("");
	final version = Signal.make("");
	final description = Signal.make("");
	final main = Signal.make("");
	final mocks = Signal.make("");
	final title = Signal.make("");
	final icon = Signal.make("");
	final newSource = Signal.make("");
	final toolId = Signal.make("");
	final toolTitle = Signal.make("");
	final toolIcon = Signal.make("");
	final cmdId = Signal.make("");
	final cmdTitle = Signal.make("");
	final cmdIcon = Signal.make("");
	final itemExt = Signal.make("");
	final itemName = Signal.make("");
	final itemTitle = Signal.make("");
	final itemIcon = Signal.make("");
	var itemCommand = "";
	var itemKind = "any";

	function render():Element {
		m = props.manifest;
		load();
		return <div id="rayde-extension-config" class="rayde-settings flex flex-1 min-h-0 justify-center overflow-auto">
			<div class="flex flex-col gap-6 px-8 py-8" width={780}>
				${SettingsParts.header(Icons.PUZZLE_LINE, "Extension", haxe.io.Path.withoutDirectory(m.file) + ". Edits are written to the file immediately.")}
				<for {r in [revision.get()]}>${sections(r)}</for>
				<div class="shrink-0" height={40}/>
			</div>
		</div>;
	}

	/** Puts what the file says in the inputs. */
	function load():Void {
		name.set(m.name);
		version.set(m.version);
		description.set(m.description);
		main.set(m.main);
		mocks.set(m.mocks);
		title.set(m.viewTitle == m.name ? "" : m.viewTitle);
		icon.set(m.viewIcon == null ? "" : m.viewIcon);
	}

	/** Runs a change to the file, then reads it again, shows it and tells the workbench. */
	function change(edit:Void->Void):Void {
		try
			edit()
		catch (e:Dynamic) {
			problem.set("Cannot write " + haxe.io.Path.withoutDirectory(m.file) + ": " + Std.string(e));
			revision.set(revision.get() + 1);
			return;
		}
		problem.set("");
		m = Manifest.read(m.file);
		load();
		revision.set(revision.get() + 1);
		props.onChanged(m);
	}

	/** Why the last change could not be written, when it could not. */
	final problem = Signal.make("");

	function sections(_:Int):Element
		return <div class="flex flex-col gap-6">
			<if {problem.get() != ""}><div class="rayde-note flex items-center gap-3 px-4 py-3"><icon document={Icons.ALERT_LINE} class="size-4 shrink-0 text-warning"/><text id="rayde-extension-write-problem" class="text-xs">${problem.get()}</text></div></if>
			<if {m.problems.length > 0}>${problems()}</if>
			${SettingsParts.card("rayde-ext-identity", "Extension", "Identifier and metadata shown in the Extensions list.", identity())}
			${SettingsParts.card("rayde-ext-scripts", "Scripts", "Entry point and module search path. Imports resolve against the first source folder.", scripts())}
			${SettingsParts.card("rayde-ext-view", "View", "Workbench contribution: activity bar icon, view title and location.", view())}
			${SettingsParts.card("rayde-ext-tools", "View actions", "Actions in the view's title bar. Invoking one calls the handler registered with onTool(id).", tools())}
			${SettingsParts.card("rayde-ext-commands", "Commands", "Commands the script registers with registerCommand(id). Listed in the command palette; bindable in Keyboard Shortcuts as ext.<id>.", commands())}
			${SettingsParts.card("rayde-ext-menus", "Explorer context menu", "Items for matching files and folders. Choosing one runs its command with { path, kind }.", menuItems())}
			${SettingsParts.card("rayde-ext-capabilities", "Capabilities", "Permissions the extension requests.", caps())}
			<div class="flex items-center gap-2">
				<button id="rayde-ext-edit-text" variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> props.onEditText()}><icon document={Icons.CODE_BOX_LINE} class="size-4"/>Open as JSON</button>
			</div>
		</div>;

	function problems():Element
		return <div id="rayde-ext-problems" class="rayde-note flex flex-col gap-1 px-4 py-3">
			{[for (p in m.problems) <div class="flex items-center gap-3"><icon document={Icons.ALERT_LINE} class="size-4 shrink-0 text-warning"/><text class="text-xs">${p}</text></div>]}
		</div>;

	// Fields

	function text(label:String, hint:String, id:String, value:Signal<String>, placeholder:String, commit:Void->Void):Element
		return SettingsParts.field(label, hint, <input height={32} id={id} value={value} placeholder={placeholder} class="rayde-control-wide" onKeyDown={e -> if (e.key.match(Named(Enter))) commit()}/>);

	function identity():Array<Element>
		return [
			text("Name", "Display name", "rayde-ext-name", name, "my-extension", () -> save("name", name)),
			text("Version", "Semantic version", "rayde-ext-version", version, "0.1.0", () -> save("version", version)),
			text("Description", "Short summary", "rayde-ext-description", description, "", () -> save("description", description))
		];

	function save(field:String, value:Signal<String>, inView = false):Void {
		var v = value.get().trim();
		change(() -> Manifest.setText(m.file, field, v, inView));
	}

	function scripts():Array<Element> {
		var out:Array<Element> = [text("Main script", "Entry script, relative to the .rayext", "rayde-ext-main", main, "main.rays", () -> save("main", main))];
		out.push(sys.FileSystem.exists(m.mainPath())
			? <div class="flex items-center gap-2"><icon document={Icons.CHECK_LINE} class="size-4 text-success"/><text id="rayde-ext-main-found" class="text-xs text-text-secondary">${relative(m.mainPath())}</text></div>
			: <div class="flex items-center gap-2"><icon document={Icons.ERROR_WARNING_LINE} class="size-4 text-warning"/><text id="rayde-ext-main-missing" class="text-xs text-warning">${m.main + " not found"}</text></div>);
		for (s in m.sources)
			out.push(row(Icons.FOLDER_LINE, s, sys.FileSystem.exists(absolute(s)) ? null : "Not found", () -> change(() -> Manifest.setList(m.file, "sources", [for (x in m.sources) if (x != s) x]))));
		out.push(<div class="flex items-center gap-2">
			<input height={32} id="rayde-ext-source" value={newSource} placeholder="Source folder" class="rayde-control-wide" onKeyDown={e -> if (e.key.match(Named(Enter))) addSource()}/>
			<button id="rayde-ext-source-add" variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> addSource()}>Add</button>
		</div>);
		out.push(text("Mocks", "JSON file that stubs remote module calls during development", "rayde-ext-mocks", mocks, "ext/studio.mocks.json", () -> save("mocks", mocks)));
		return out;
	}

	function addSource():Void {
		var v = newSource.get().trim();
		if (v == "" || m.sources.indexOf(v) >= 0)
			return;
		newSource.set("");
		change(() -> Manifest.setList(m.file, "sources", m.sources.concat([v])));
	}

	function view():Array<Element> {
		var doc = ViewIcons.of(m);
		var items:Array<Element> = [for (l in locations) <select-item value={l.id}>${l.label}</select-item>];
		var found = m.viewIcon == null ? null : (sys.FileSystem.exists(m.iconPath()));
		var out:Array<Element> = [
			text("Title", "View title. Scripts can change it with setTitle(). Defaults to the extension name", "rayde-ext-title", title, m.name, () -> save("title", title, true)),
			SettingsParts.field("Location", "Where the view is rendered",
				<select id="rayde-ext-location" value={m.location} size={Sm} class="rayde-control" onChange={v -> change(() -> Manifest.setText(m.file, "location", v == "sidebar" ? null : v, true))}>{items}</select>),
			SettingsParts.field("Icon", "SVG file for the activity bar icon. Defaults to the generic extension icon",
				<div class="flex items-center gap-3">
					<div id="rayde-ext-icon-preview" class="rayde-tile flex items-center justify-center shrink-0" width={32} height={32}><icon document={doc} class="size-4"/></div>
					<input height={32} id="rayde-ext-icon" value={icon} placeholder="ext/icon.svg" class="rayde-control-wide" onKeyDown={e -> if (e.key.match(Named(Enter))) save("icon", icon, true)}/>
				</div>)
		];
		if (m.viewIcon != null && found == false)
			out.push(<div class="flex items-center gap-2"><icon document={Icons.ERROR_WARNING_LINE} class="size-4 text-warning"/><text id="rayde-ext-icon-missing" class="text-xs text-warning">${m.viewIcon + " not found"}</text></div>);
		var svgs = svgFiles();
		if (svgs.length > 0)
			out.push(chips("SVG files", [for (s in svgs) {label: s, run: () -> change(() -> Manifest.setText(m.file, "icon", s, true))}]));
		return out;
	}

	function tools():Array<Element> {
		var out:Array<Element> = [
			for (t in m.tools)
				toolRow(t)
		];
		if (m.tools.length == 0)
			out.push(<text class="text-xs text-text-tertiary">No actions declared.</text>);
		out.push(<div class="flex items-center gap-2">
			<input height={32} id="rayde-ext-tool-id" value={toolId} placeholder="Action id" class="rayde-control-narrow" onKeyDown={e -> if (e.key.match(Named(Enter))) addTool()}/>
			<input height={32} id="rayde-ext-tool-title" value={toolTitle} placeholder="Tooltip" class="rayde-control-narrow" onKeyDown={e -> if (e.key.match(Named(Enter))) addTool()}/>
			<input height={32} id="rayde-ext-tool-icon" value={toolIcon} placeholder="Icon name or .svg path" class="rayde-control" onKeyDown={e -> if (e.key.match(Named(Enter))) addTool()}/>
			<button id="rayde-ext-tool-add" variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> addTool()}>Add</button>
		</div>);
		out.push(chips("Built-in icons", [for (n in ["add", "refresh", "search", "filter", "settings", "play", "stop", "edit", "delete", "more"]) {label: n, run: () -> toolIcon.set(n)}]));
		return out;
	}

	function toolRow(t:rayde.ext.Manifest.ViewTool):Element
		return <div class="rayde-setting-row flex items-center gap-3 px-3" height={40}>
			<icon document={ViewIcons.tool(m, t)} class="size-4 shrink-0 text-text-secondary"/>
			<text class="rayde-mono text-sm">${t.id}</text>
			<text class="text-xs text-text-tertiary flex-1 min-w-0">${t.title == t.id ? "" : t.title}${t.icon == null ? "" : "   " + t.icon}</text>
			<tooltip label="Remove"><button variant={Ghost} size={Icon} class="rayde-remove" onClick={_ -> change(() -> Manifest.removeTool(m.file, t.id))}><icon document={Icons.CLOSE_LINE} class="size-4"/></button></tooltip>
		</div>;

	function addTool():Void {
		var id = toolId.get().trim();
		if (id == "")
			return;
		var title = toolTitle.get().trim(), icon = toolIcon.get().trim();
		toolId.set("");
		toolTitle.set("");
		toolIcon.set("");
		change(() -> Manifest.addTool(m.file, {id: id, title: title == "" ? id : title, icon: icon == "" ? null : icon}));
	}

	function commands():Array<Element> {
		var out:Array<Element> = [for (c in m.commands) commandRow(c)];
		if (m.commands.length == 0)
			out.push(<text class="text-xs text-text-tertiary">No commands declared.</text>);
		out.push(<div class="flex items-center gap-2">
			<input height={32} id="rayde-ext-cmd-id" value={cmdId} placeholder="Command id" class="rayde-control-narrow" onKeyDown={e -> if (e.key.match(Named(Enter))) addCommand()}/>
			<input height={32} id="rayde-ext-cmd-title" value={cmdTitle} placeholder="Title" class="rayde-control-narrow" onKeyDown={e -> if (e.key.match(Named(Enter))) addCommand()}/>
			<input height={32} id="rayde-ext-cmd-icon" value={cmdIcon} placeholder="Icon name or .svg path" class="rayde-control" onKeyDown={e -> if (e.key.match(Named(Enter))) addCommand()}/>
			<button id="rayde-ext-cmd-add" variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> addCommand()}>Add</button>
		</div>);
		var svgs = svgFiles();
		if (svgs.length > 0)
			out.push(chips("SVG files", [for (s in svgs) {label: s, run: () -> cmdIcon.set(s)}]));
		return out;
	}

	function commandRow(c:rayde.ext.Manifest.ViewCommand):Element {
		var icon = ViewIcons.named(m, c.icon);
		return <div class="rayde-setting-row flex items-center gap-3 px-3" height={40}>
			<icon document={icon == null ? Icons.PUZZLE_LINE : icon} class="size-4 shrink-0 text-text-secondary"/>
			<text class="rayde-mono text-sm">${c.id}</text>
			<text class="text-xs text-text-tertiary flex-1 min-w-0">${c.title == c.id ? "" : c.title}${c.icon == null ? "" : "   " + c.icon}</text>
			<tooltip label="Remove"><button variant={Ghost} size={Icon} class="rayde-remove" onClick={_ -> change(() -> Manifest.removeCommand(m.file, c.id))}><icon document={Icons.CLOSE_LINE} class="size-4"/></button></tooltip>
		</div>;
	}

	function addCommand():Void {
		var id = cmdId.get().trim();
		if (id == "")
			return;
		var title = cmdTitle.get().trim(), icon = cmdIcon.get().trim();
		cmdId.set("");
		cmdTitle.set("");
		cmdIcon.set("");
		change(() -> Manifest.addCommand(m.file, {id: id, title: title == "" ? id : title, icon: icon == "" ? null : icon}));
	}

	static final EXPLORER = "explorer/context";

	/** What an item applies to, as the row says it: kind, extensions, name pattern. */
	static function whenText(w:MenuWhen):String {
		var parts = [w.kind == null ? "file or folder" : w.kind];
		if (w.ext.length > 0)
			parts.push(w.ext.join(", "));
		if (w.name != null)
			parts.push(w.name);
		return parts.join("  ·  ");
	}

	function menuItems():Array<Element> {
		var items = m.menus.get(EXPLORER);
		var out:Array<Element> = [];
		if (items != null)
			for (i => item in items)
				out.push(menuRow(i, item));
		if (items == null || items.length == 0)
			out.push(<text class="text-xs text-text-tertiary">No menu items declared.</text>);
		if (m.commands.length == 0) {
			out.push(<text class="text-xs text-text-tertiary">Declare a command to add a menu item.</text>);
			return out;
		}
		if (!Lambda.exists(m.commands, c -> c.id == itemCommand))
			itemCommand = m.commands[0].id;
		var commandItems:Array<Element> = [for (c in m.commands) <select-item value={c.id}>${c.id}</select-item>];
		var kinds:Array<Element> = [<select-item value="any">File or folder</select-item>, <select-item value="file">File</select-item>, <select-item value="folder">Folder</select-item>];
		out.push(<div class="flex items-center gap-2">
			<select id="rayde-ext-item-command" value={itemCommand} size={Sm} class="rayde-control" onChange={v -> itemCommand = v}>{commandItems}</select>
			<select id="rayde-ext-item-kind" value={itemKind} size={Sm} class="rayde-control" onChange={v -> itemKind = v}>{kinds}</select>
			<input height={32} id="rayde-ext-item-ext" value={itemExt} placeholder="Extensions: .md, .markdown" class="rayde-control-wide" onKeyDown={e -> if (e.key.match(Named(Enter))) addMenuItem()}/>
		</div>);
		out.push(<div class="flex items-center gap-2">
			<input height={32} id="rayde-ext-item-name" value={itemName} placeholder="Name pattern: README*" class="rayde-control-narrow" onKeyDown={e -> if (e.key.match(Named(Enter))) addMenuItem()}/>
			<input height={32} id="rayde-ext-item-title" value={itemTitle} placeholder="Title override" class="rayde-control-narrow" onKeyDown={e -> if (e.key.match(Named(Enter))) addMenuItem()}/>
			<input height={32} id="rayde-ext-item-icon" value={itemIcon} placeholder="Icon override" class="rayde-control" onKeyDown={e -> if (e.key.match(Named(Enter))) addMenuItem()}/>
			<button id="rayde-ext-item-add" variant={Secondary} size={Sm} class="rayde-add" onClick={_ -> addMenuItem()}>Add</button>
		</div>);
		return out;
	}

	function menuRow(index:Int, item:MenuItem):Element {
		var command = Lambda.find(m.commands, c -> c.id == item.command);
		var icon = ViewIcons.named(m, item.icon != null ? item.icon : command == null ? null : command.icon);
		return <div class="rayde-setting-row flex items-center gap-3 px-3" height={40}>
			<icon document={icon == null ? Icons.PUZZLE_LINE : icon} class="size-4 shrink-0 text-text-secondary"/>
			<text class="rayde-mono text-sm">${item.command}</text>
			<text class="text-xs text-text-tertiary flex-1 min-w-0 truncate">${whenText(item.when)}</text>
			<tooltip label="Remove"><button variant={Ghost} size={Icon} class="rayde-remove" onClick={_ -> change(() -> Manifest.removeMenuItem(m.file, EXPLORER, index))}><icon document={Icons.CLOSE_LINE} class="size-4"/></button></tooltip>
		</div>;
	}

	function addMenuItem():Void {
		if (itemCommand == "")
			return;
		var exts = [for (e in ~/[,\s]+/.split(itemExt.get())) e.toLowerCase()];
		var seen:Array<String> = [];
		for (e in exts)
			if (e != "") {
				var dotted = e.startsWith(".") ? e : "." + e;
				if (seen.indexOf(dotted) < 0)
					seen.push(dotted);
			}
		var name = itemName.get().trim(), title = itemTitle.get().trim(), icon = itemIcon.get().trim();
		itemExt.set("");
		itemName.set("");
		itemTitle.set("");
		itemIcon.set("");
		change(() -> Manifest.addMenuItem(m.file, EXPLORER, {
			command: itemCommand,
			title: title == "" ? null : title,
			icon: icon == "" ? null : icon,
			when: {kind: itemKind == "any" ? null : itemKind, ext: seen, name: name == "" ? null : name}
		}));
	}

	function caps():Array<Element> {
		var out:Array<Element> = [
			for (c in capabilities)
				SettingsParts.field(c.label, c.hint + " (" + c.id + ")",
					<toggle-switch id={"rayde-ext-cap-" + c.id} checked={m.capabilities.indexOf(c.id) >= 0} size={Sm} onChange={on -> setCapability(c.id, on)}/>)
		];
		for (c in m.capabilities)
			if (!Lambda.exists(capabilities, k -> k.id == c))
				out.push(row(Icons.QUESTION_LINE, c, "Unknown capability", () -> setCapability(c, false)));
		return out;
	}

	function setCapability(id:String, on:Bool):Void {
		var rest = [for (c in m.capabilities) if (c != id) c];
		change(() -> Manifest.setList(m.file, "capabilities", on ? rest.concat([id]) : rest));
	}

	// Pieces

	function absolute(path:String):String
		return haxe.io.Path.isAbsolute(path) ? path : haxe.io.Path.join([m.root, path]);

	function relative(path:String):String {
		var root = haxe.io.Path.addTrailingSlash(m.root);
		return path.startsWith(root) ? path.substr(root.length) : path;
	}

	/** The SVG files under the project, as paths from the config's folder, for choosing an icon from. */
	function svgFiles():Array<String> {
		var out = [];
		function walk(dir:String, depth:Int):Void {
			if (depth > 3)
				return;
			var names = sys.FileSystem.readDirectory(dir);
			names.sort(Reflect.compare);
			for (n in names) {
				var path = haxe.io.Path.join([dir, n]);
				if (n.startsWith("."))
					continue;
				if (sys.FileSystem.isDirectory(path))
					walk(path, depth + 1);
				else if (n.endsWith(".svg"))
					out.push(relative(path));
			}
		}
		walk(m.root, 0);
		return out.length > 8 ? out.slice(0, 8) : out;
	}

	function row(icon:ashui.svg.SvgDocument, text:String, warning:Null<String>, remove:Void->Void):Element
		return <div class="rayde-setting-row flex items-center gap-3 px-3" height={40}>
			<icon document={icon} class="size-4 shrink-0 text-text-secondary"/>
			<text class="rayde-mono text-sm flex-1 min-w-0">${text}</text>
			<if {warning != null}><text class="text-xs text-warning">${warning}</text></if>
			<tooltip label="Remove"><button variant={Ghost} size={Icon} class="rayde-remove" onClick={_ -> remove()}><icon document={Icons.CLOSE_LINE} class="size-4"/></button></tooltip>
		</div>;

	function chips(title:String, items:Array<{label:String, run:Void->Void}>):Element
		return <div class="flex items-center gap-2 flex-wrap">
			<text class="text-xs text-text-tertiary">${title}</text>
			{[for (i in items) chip(i.label, i.run)]}
		</div>;

	function chip(label:String, run:Void->Void):Element
		return <button variant={Outline} size={Sm} class="rayde-chip" onClick={_ -> run()}>${label}</button>;
}
