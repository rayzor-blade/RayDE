package rayde.ui;

import ashui.components.Button;
import ashui.components.Dialog;
import ashui.components.Icon;
import ashui.css.Identity;
import ashui.layout.Element;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.ui.Component;
import ashui.ui.Ref;
import rayde.workspace.Fs;

typedef WorkspacePickerProps = {
	opened:Signal<Bool>, root:String, directory:String, folder:Bool,
	?title:String, complete:Null<String>->Void
};
typedef WorkspacePickerEntry = {path:String,name:String,directory:Bool};
private typedef Listing = {directory:String, entries:Array<WorkspacePickerEntry>};

/** Browses the mounted session through Fs; directory IO never runs on the UI thread. */
class WorkspacePicker extends Component<WorkspacePickerProps> {
	final directory = Signal.make("");
	final address = Signal.make("");
	final selected = Signal.make("");
	final busy = Signal.make(false);
	final error = Signal.make("");
	final listing = Signal.make((null:Null<Listing>));
	final location = new Ref<ashui.ui.Input>();
	final jobs = new rayde.run.Worker<{root:String,directory:String,folder:Bool}, Listing>(read);
	var timer:Null<ashui.animation.AnimationScheduler.Timer>;
	var gone = false;
	var finished = false;

	function render():Element {
		load(rayde.files.FileOps.inside(props.root,props.directory) ? props.directory : props.root);
		Owner.onCleanup(() -> { gone = true; jobs.dispose(); if (timer != null) timer.cancel(); });
		return <dialog id="rayde-workspace-picker" open={props.opened} onOpenChange={on -> if (!on) finish(null)}>
			<dialog-content id="rayde-workspace-browser" size={Lg} onKeyDown={event -> {
				if ((event.alt || event.superKey) && event.key.match(Named(ArrowUp))) { up(); event.preventDefault(); event.stopPropagation(); }
				if (event.control && (event.key.match(Character("l")) || event.key.match(Character("L"))) || event.superKey && event.shift && (event.key.match(Character("g")) || event.key.match(Character("G")))) {
					var input = location.get(); if (input != null) { input.focus(); input.editing.anchor.set(0); input.editing.caret.set(address.get().length); }
					event.preventDefault(); event.stopPropagation();
				}
			}}>
				<dialog-header><dialog-title>${props.title ?? (props.folder ? "Open Folder Workspace" : "Open Project")}</dialog-title>
					<dialog-description>Browse the workspace connected to this editor.</dialog-description></dialog-header>
				<div class="flex flex-row items-center gap-2">
					<button id="rayde-workspace-up" variant={Ghost} size={Icon} disabled={directory.get() == props.root} onClick={_ -> up()}><icon document={Icons.ARROW_UP_LINE} class="size-4"/></button>
					<input ref={location} id="rayde-workspace-location" class="flex-1 min-w-0" value={address} onKeyDown={e -> if (e.key.match(Named(Enter))) { load(address.get()); e.preventDefault(); e.stopPropagation(); }}/>
				</div>
				<div height={280} class="flex flex-col min-h-0">
					<if {busy.get()}><text class="text-sm text-text-secondary p-3">Loading…</text>
					<else><for {data in [listing.get()]}><if {data != null}>${rows(data)}</if></for></if>
				</div>
				<if {error.get() != ""}><text class="text-sm text-error">${error.get()}</text></if>
				<dialog-footer><button id="rayde-workspace-cancel" variant={Outline} onClick={_ -> finish(null)}>Cancel</button>
					<button id="rayde-workspace-open" disabled={busy.get() || !props.folder && selected.get() == ""} onClick={_ -> accept()}>${props.folder ? "Choose Folder" : "Open"}</button></dialog-footer>
			</dialog-content>
		</dialog>;
	}

	function rows(data:Listing):Element {
		var box = <div id="rayde-workspace-entries" class="flex flex-col overflow-auto" height={280}/>;
		var scroll = ashui.input.Scroll.attach(box.node,false,true), entries = data.entries;
		var first = ashui.reactive.Computed.make(() -> Std.int(Math.max(0,Math.floor(scroll.y.get()/28)-3)));
		var end = ashui.reactive.Computed.make(() -> Std.int(Math.min(entries.length,first.get()+17)));
		var shown = ashui.reactive.Computed.make(() -> entries.slice(first.get(),end.get()));
		box.appendChild(<div height={ashui.reactive.Computed.make(() -> first.get()*28.)} flexShrink={0}/>);
		box.appendChild(<for {entry in shown}>${entryRow(entry)}</for>);
		box.appendChild(<div height={ashui.reactive.Computed.make(() -> (entries.length-end.get())*28.)} flexShrink={0}/>);
		if (entries.length == 0) box.appendChild(<text class="text-sm text-text-secondary p-3">No matching items</text>);
		return box;
	}
	function entryRow(entry:WorkspacePickerEntry):Element {
		var row = <button id={"rayde-workspace-entry-" + haxe.crypto.Md5.encode(entry.path)} class="rayde-workspace-entry" variant={Ghost} onClick={event -> {
			selected.set(entry.path);
			if (event.clickCount >= 2) { if (entry.directory) load(entry.path); else finish(entry.path); }
		}}><icon document={entry.directory ? Icons.FOLDER_LINE : FileIcons.of(entry.path)} class="size-4 shrink-0"/><text wrap={false}>${entry.name}</text></button>;
		var identity = Identity.of(row.tree,row.node.id); identity.setAttribute("data-path",entry.path);
		new ashui.reactive.Watch(() -> selected.get() == entry.path, on -> identity.setAttribute("data-selected",on ? "" : null));
		ashui.input.Interaction.of(row.node).onKeyDown(e -> if (e.key.match(Named(Enter))) { if (entry.directory) load(entry.path); else finish(entry.path); e.preventDefault(); e.stopPropagation(); });
		return row;
	}

	function up():Void { if (directory.get() != props.root) load(haxe.io.Path.directory(directory.get())); }
	function load(path:String):Void {
		if (!rayde.files.FileOps.inside(props.root,path))
			path = haxe.io.Path.join([StringTools.startsWith(path,"/") || directory.get() == "" ? props.root : directory.get(), StringTools.startsWith(path,"/") ? path.substr(1) : path]);
		path = haxe.io.Path.normalize(path);
		if (!rayde.files.FileOps.inside(props.root,path)) { error.set("Choose a folder in this workspace."); return; }
		directory.set(path); address.set(path == props.root ? "/" : "/" + rayde.files.FileOps.relative(props.root,path)); selected.set(""); busy.set(true); error.set("");
		jobs.submit("list",{root:props.root,directory:path,folder:props.folder});
		if (timer == null) timer = ashui.animation.AnimationScheduler.main.after(.016,poll);
	}
	function poll():Void {
		timer = null; if (gone) return;
		for (result in jobs.poll()) {
			busy.set(false);
			if (result.error != null) { error.set(result.error); listing.set(null); }
			else listing.set(result.value);
		}
		if (busy.get()) timer = ashui.animation.AnimationScheduler.main.after(.03,poll);
	}
	function accept():Void {
		var found = listing.get(); if (busy.get() || found == null) return;
		var entry = Lambda.find(found.entries,entry -> entry.path == selected.get());
		if (entry != null && entry.directory) { if (props.folder) finish(entry.path); else load(entry.path); }
		else if (props.folder) finish(found.directory);
		else if (entry != null) finish(entry.path);
	}
	function finish(path:Null<String>):Void {
		if (finished || gone) return;
		finished = true; props.complete(path); props.opened.set(false);
	}
	static function read(request:{root:String,directory:String,folder:Bool}, cancelled:Void->Bool):Listing {
		if (!rayde.files.FileOps.inside(request.root,request.directory)) throw "Choose a folder in this workspace.";
		var entries = [];
		for (name in Fs.readDirectory(request.directory)) {
			if (cancelled()) break;
			var path = haxe.io.Path.join([request.directory,name]), folder = Fs.isDirectory(path);
			if (folder || !request.folder && (rayde.project.ProjectFile.supported(path) || rayde.ext.Manifest.isManifest(path) || rayde.theme.ThemeFile.isThemeFile(path))) entries.push({path:path,name:name,directory:folder});
		}
		entries.sort((a,b) -> a.directory != b.directory ? a.directory ? -1 : 1 : Reflect.compare(a.name.toLowerCase(),b.name.toLowerCase()));
		return {directory:request.directory,entries:entries};
	}
}
