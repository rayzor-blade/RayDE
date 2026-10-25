package rayde.ui;

import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.build.HxmlFile;
import rayde.run.Haxelib;
import rayde.run.LibraryManager;

using StringTools;

/** A library as the column shows it: whether the build names it, whether haxelib has it, and which version. */
private typedef LibraryRow = {name:String, entry:String, pin:Null<String>, used:Bool, version:String, installed:Bool};

typedef LibrarySettingsProps = {
	/** The build file, whose -lib arguments say which libraries the build uses; null when the project has none. */
	file:Null<HxmlFile>,
	root:String,
	manager:LibraryManager,
	/** Called after a change has been written to the build file. */
	onChanged:Void->Void
};

/**
 * The libraries haxelib has on this machine, and which of them the build uses: one click puts a library in or
 * out of the build file, a name typed in adds one to it and installs it when haxelib lacks it, and each
 * installed library can be updated or removed. haxelib runs in the background and its last line is shown.
 */
class LibrarySettings extends Component<LibrarySettingsProps> {
	final revision = Signal.make(0);
	final query = Signal.make("");
	final version = Signal.make("");
	var polling = false;
	var gone = false;
	var catalog:Array<rayde.run.Haxelib.Lib> = [];
	var catalogQuery:Null<ash.Future<Array<rayde.run.Haxelib.Lib>>>;
	final loading = Signal.make(false);

	function render():Element {
		var receive:ashui.layout.LayoutTree->Void = tree -> if (tree == this.tree && !gone && catalogQuery != null && catalogQuery.isReady()) {
			catalog = catalogQuery.await(); catalogQuery = null; loading.set(false); revision.set(revision.get() + 1);
		};
		ashui.layout.LayoutTree.flushHooks.push(receive);
		Owner.onCleanup(() -> { gone = true; ashui.layout.LayoutTree.flushHooks.remove(receive); });
		loadCatalog(); resume();
		return SettingsParts.page("rayde-libraries", <div class="flex flex-col gap-6">
			${SettingsParts.header(Icons.BOOK_2_LINE, "Libraries", "Haxe libraries from haxelib, and the ones this build uses.")}
			<for {r in [revision.get()]}>${sections(r)}</for>
		</div>);
	}

	function loadCatalog():Void {
		catalogQuery = Haxelib.installedAsync();
		if (catalogQuery.isReady()) { catalog = catalogQuery.await(); catalogQuery = null; loading.set(false); }
		else { loading.set(true); catalogQuery.then(_ -> ashui.core.Work.notify()); }
	}

	function sections(_:Int):Element
		return <div class="flex flex-col gap-6">
			${SettingsParts.card("rayde-libraries-card", "haxelib", props.file == null ? "Libraries installed on this machine." : "Click a library to put it in the build (-lib) or take it out. Add installs one haxelib does not have.", [adder(), status(), list()])}
		</div>;

	function adder():Element
		return <div class="flex items-center gap-2">
			<input height={32} id="rayde-library-name" value={query} placeholder="Filter, or type a library to add" class="rayde-control-wide" onKeyDown={e -> if (e.key.match(Named(Enter))) add()}/>
			<input height={32} id="rayde-library-version" value={version} placeholder="Version (optional)" class="rayde-control-narrow" onKeyDown={e -> if (e.key.match(Named(Enter))) add()}/>
			<button id="rayde-library-add" variant={Secondary} size={Sm} class="rayde-add" disabled={props.manager.busy() || loading.get()} onClick={_ -> add()}>${props.file == null ? "Install" : "Add"}</button>
		</div>;

	/** What haxelib is doing, or how its last job ended. */
	function status():Element {
		if (loading.get()) return <text id="rayde-library-loading" class="text-xs text-text-secondary">Loading libraries…</text>;
		var m = props.manager;
		if (m.busy())
			return <div class="flex items-center gap-2"><icon document={Icons.REFRESH_LINE} class="size-4 text-text-secondary"/><text id="rayde-library-status" class="text-xs text-text-secondary">${m.doing + "..."}</text></div>;
		if (m.message == "")
			return <div/>;
		return m.failed ? <div class="flex items-center gap-2"><icon document={Icons.ERROR_WARNING_LINE} class="size-4 text-warning"/><text id="rayde-library-status" class="text-xs text-warning">${m.message}</text></div> : <div class="flex items-center gap-2"><icon document={Icons.CHECK_LINE} class="size-4 text-success"/><text id="rayde-library-status" class="text-xs text-text-secondary">${m.message}</text></div>;
	}

	function list():Element
		return <div class="flex flex-col"><for {q in [query.get()]}>${libraryList(q)}</for></div>;

	/** A column of the build's libraries first and the installed ones after. */
	function libraryList(text:String):Element {
		var used = props.file == null ? [] : props.file.values("-lib"), installed = catalog, filter = text.trim().toLowerCase();
		var rows:Array<LibraryRow> = [], seen = new Map<String, Bool>();
		for (entry in used) {
			var colon = entry.indexOf(":"), name = colon < 0 ? entry : entry.substr(0, colon);
			var lib = Lambda.find(installed, i -> i.name == name);
			rows.push({name: name, entry: entry, pin: colon < 0 ? null : entry.substr(colon + 1), used: true, version: lib == null ? "" : lib.version, installed: lib != null});
			seen.set(name, true);
		}
		for (lib in installed)
			if (!seen.exists(lib.name))
				rows.push({name: lib.name, entry: lib.name, pin: null, used: false, version: lib.version, installed: true});
		var shown = [for (r in rows) if (filter == "" || r.name.toLowerCase().indexOf(filter) >= 0) r];
		return WindowedRows.make("rayde-library-list", "rayde-lib-list", shown, 36, 264, libraryRow,
			filter == "" ? "No libraries." : "No library matches. Add installs " + text.trim() + ".");
	}

	function libraryRow(r:LibraryRow):Element {
		var busy = props.manager.busy() || loading.get();
		return <div id={"rayde-lib-" + r.name} class="rayde-lib-row flex items-center gap-3 px-3 shrink-0 cursor-pointer" height={36} onClick={_ -> toggle(r)}>
			<if {props.file != null}>
				<if {r.used}><icon document={Icons.CHECKBOX_CIRCLE_FILL} class="size-4 text-primary shrink-0"/>
				<else><icon document={Icons.CHECKBOX_BLANK_CIRCLE_LINE} class="size-4 text-text-tertiary shrink-0"/></if>
			</if>
			<text class="rayde-mono text-sm flex-1 min-w-0">${r.name}</text>
			<text class="text-xs text-text-tertiary">${r.pin != null ? "pinned " + r.pin : r.version}</text>
			<if {r.installed}>
				<div class="flex items-center gap-1 shrink-0">
				<tooltip label="Update"><button id={"rayde-lib-update-" + r.name} variant={Ghost} size={Icon} class="rayde-remove" disabled={busy} onClick={e -> { e.stopPropagation(); run(() -> props.manager.update(r.name)); }}><icon document={Icons.REFRESH_LINE} class="size-4"/></button></tooltip>
				<tooltip label="Remove from this machine"><button id={"rayde-lib-remove-" + r.name} variant={Ghost} size={Icon} class="rayde-remove" disabled={busy} onClick={e -> { e.stopPropagation(); run(() -> props.manager.remove(r.name)); }}><icon document={Icons.DELETE_BIN_LINE} class="size-4"/></button></tooltip>
				</div>
			<else>
				<button id={"rayde-lib-install-" + r.name} variant={Outline} size={Sm} class="rayde-chip" disabled={busy} onClick={e -> { e.stopPropagation(); run(() -> props.manager.install(r.name, r.pin == null ? "" : r.pin)); }}>Install</button>
			</if>
		</div>;
	}

	/** Puts the library in the build or takes it out; a click on a row of a project with no build file does nothing. */
	function toggle(r:LibraryRow):Void {
		if (props.file == null)
			return;
		change(() -> if (r.used) props.file.remove("-lib", r.entry) else props.file.add("-lib", r.name));
	}

	function add():Void {
		var name = query.get().trim(), pin = version.get().trim();
		if (name == "" || props.manager.busy() || loading.get())
			return;
		query.set("");
		version.set("");
		var installed = Lambda.exists(catalog, i -> i.name == name);
		if (props.file != null)
			change(() -> props.file.add("-lib", pin == "" ? name : name + ":" + pin));
		if (!installed)
			run(() -> props.manager.install(name, pin));
	}

	/** Writes a change to the build file, shows the result, and tells the workbench. */
	function change(edit:Void->Void):Void {
		edit();
		props.file.save();
		revision.set(revision.get() + 1);
		props.onChanged();
	}

	/** Starts a haxelib job and watches it until it ends. */
	function run(start:Void->Void):Void {
		start();
		revision.set(revision.get() + 1);
		resume();
	}

	/** While a job runs, looks at it a few times a second; a window that is otherwise still draws no frames to do it from. */
	function resume():Void {
		if (polling || gone || !props.manager.busy())
			return;
		polling = true;
		var step:Void->Void = null;
		step = () -> {
			if (gone) {
				polling = false;
				return;
			}
			if (props.manager.tick()) {
				loadCatalog(); revision.set(revision.get() + 1);
			}
			if (props.manager.busy())
				ashui.animation.AnimationScheduler.main.after(.15, step);
			else
				polling = false;
		};
		ashui.animation.AnimationScheduler.main.after(.15, step);
	}
}
