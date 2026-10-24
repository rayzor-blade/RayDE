package rayde.ui;

import ashui.components.CodeEditor;
import ashui.layout.Element;
import ashui.reactive.Signal;
import rayde.ui.CommandCenter.CenterAction;

/** An icon in the activity bar. `on` says whether it shows as selected; it is read reactively. */
typedef ActivityEntry = {id:String, title:String, icon:ashui.svg.SvgDocument, ?place:String, ?order:Int, on:Void->Bool, run:Void->Void};

/** An item in the status bar, built where it is shown: `place` is `left` or `right`, and it reads whatever signals it needs. */
typedef StatusEntry = {id:String, ?place:String, ?order:Int, build:Void->Element};

private typedef Ordered<T> = {order:Int, serial:Int, value:T};

/**
	What the parts of the IDE offer each other: commands for the command center and key bindings, icons for the activity bar,
	items for the status bar, views for the side panel, and the moments of the workbench they want to know about. A feature
	registers what it has when it is installed and gets back a function that takes it away again. The workbench and its bars
	list what is registered and name no feature.
**/
class Contributions {
	/** Changes when something is registered or removed, so what lists the entries lists them again. */
	public final revision = Signal.make(0);

	var serial = 0;
	final commandEntries:Array<Ordered<CenterAction>> = [];
	final commandSources:Array<Void->Array<CenterAction>> = [];
	final activityEntries:Array<Ordered<ActivityEntry>> = [];
	final activitySources:Array<Void->Array<ActivityEntry>> = [];
	final statusEntries:Array<Ordered<StatusEntry>> = [];
	final sidebars = new Map<String, Void->Element>();
	final editorHooks:Array<(String, CodeEditor)->Void> = [];
	final activeHooks:Array<String->Void> = [];
	final navigationHooks:Array<Void->Void> = [];
	final editedHooks:Array<String->Void> = [];
	final frameHooks:Array<Void->Void> = [];
	final retainers:Array<Void->Array<String>> = [];
	final refusals:Array<(String, String)->Null<String>> = [];
	final closeHooks:Array<Void->Void> = [];
	final readOnlyChecks:Array<String->Bool> = [];

	public function new() {}

	function changed():Void
		revision.set(revision.get() + 1);

	static function remove<T>(list:Array<T>, item:T):Void {
		for (i in 0...list.length)
			if (Reflect.compareMethods(list[i], item) || list[i] == item) {
				list.splice(i, 1);
				return;
			}
	}

	function add<T>(list:Array<Ordered<T>>, value:T, order:Null<Int>, same:T->Bool):Void->Void {
		var entry = {order: order ?? 100, serial: serial++, value: value};
		var at = -1;
		for (i in 0...list.length) if (same(list[i].value)) { at = i; break; }
		if (at >= 0) { entry = {order: order ?? list[at].order, serial: list[at].serial, value: value}; list[at] = entry; }
		else list.push(entry);
		changed();
		return () -> { list.remove(entry); changed(); };
	}

	static function sorted<T>(list:Array<Ordered<T>>):Array<T> {
		var copy = list.copy();
		copy.sort((a, b) -> a.order != b.order ? a.order - b.order : a.serial - b.serial);
		return [for (e in copy) e.value];
	}

	// --- Commands ---

	/** A command for the command center and key bindings; a command with the same id is replaced. */
	public function command(entry:CenterAction, ?order:Int):Void->Void
		return add(commandEntries, entry, order, e -> e.id == entry.id);

	/** Commands that are asked for when listed, as those of extensions are. */
	public function commandSource(source:Void->Array<CenterAction>):Void->Void {
		commandSources.push(source);
		changed();
		return () -> { commandSources.remove(source); changed(); };
	}

	public function commands():Array<CenterAction> {
		var out = sorted(commandEntries);
		for (source in commandSources) out = out.concat(source());
		return out;
	}

	// --- Activity bar ---

	/** An icon at the top (`top`, the default) or the bottom of the activity bar. */
	public function activity(entry:ActivityEntry):Void->Void
		return add(activityEntries, entry, entry.order, e -> e.id == entry.id);

	/** Icons that are asked for when listed, as those of extension views are. */
	public function activitySource(source:Void->Array<ActivityEntry>):Void->Void {
		activitySources.push(source);
		changed();
		return () -> { activitySources.remove(source); changed(); };
	}

	/** The icons of one end of the activity bar, in order; the sources come after the entries of the same order. */
	public function activityItems(place:String):Array<ActivityEntry> {
		revision.get();
		var out = [for (e in sorted(activityEntries)) if ((e.place ?? "top") == place) e];
		for (source in activitySources) for (e in source()) if ((e.place ?? "top") == place) out.push(e);
		return out;
	}

	// --- Status bar ---

	/** An item of the status bar; one with the same id is replaced in the same place. */
	public function status(entry:StatusEntry):Void->Void
		return add(statusEntries, entry, entry.order, e -> e.id == entry.id);

	public function removeStatus(id:String):Void {
		for (e in statusEntries.copy()) if (e.value.id == id) statusEntries.remove(e);
		changed();
	}

	/** The ids of the status items registered, for those who own several. */
	public function statusIds():Array<String>
		return [for (e in statusEntries) e.value.id];

	public function statusItems(place:String):Array<StatusEntry> {
		revision.get();
		return [for (e in sorted(statusEntries)) if ((e.place ?? "left") == place) e];
	}

	// --- Side panel ---

	/** A view for the side panel, shown while the workbench's side view is `id`. */
	public function sidebar(id:String, build:Void->Element):Void->Void {
		sidebars.set(id, build);
		changed();
		return () -> { sidebars.remove(id); changed(); };
	}

	public function hasSidebar(id:String):Bool
		return sidebars.exists(id);

	public function sidebarView(id:String):Null<Void->Element>
		return sidebars.get(id);

	// --- Moments ---

	/** Called with a file and its editor each time an editor for it is made. */
	public function onEditor(hook:(String, CodeEditor)->Void):Void
		editorHooks.push(hook);

	/** Called with the file that has come to the front, or "" when none has. */
	public function onActive(hook:String->Void):Void
		activeHooks.push(hook);

	/** Called when the user moves to somewhere in the workbench by command: opening a file, find, and the like. */
	public function onNavigate(hook:Void->Void):Void
		navigationHooks.push(hook);

	/** Called with a file whose buffer has changed. */
	public function onEdited(hook:String->Void):Void
		editedHooks.push(hook);

	/** Called each time the interface has been updated, for work that is waiting on it. */
	public function onFrame(hook:Void->Void):Void
		frameHooks.push(hook);

	/** Files a feature still needs the text of, which are kept although no tab shows them. */
	public function retains(files:Void->Array<String>):Void
		retainers.push(files);

	/** Called with a path and what is about to be done to it (`renaming`, `deleting`); a message refuses it. */
	public function refuses(check:(String, String)->Null<String>):Void
		refusals.push(check);

	/** Says that a file's editor takes no typing for now; it is read reactively, so it may depend on signals. */
	public function readOnlyWhen(check:String->Bool):Void
		readOnlyChecks.push(check);

	public function readOnly(file:String):Bool {
		for (check in readOnlyChecks) if (check(file)) return true;
		return false;
	}

	/** Called when the workbench is closing. */
	public function onClose(hook:Void->Void):Void
		closeHooks.push(hook);

	public function editorMade(file:String, editor:CodeEditor):Void
		for (hook in editorHooks.copy()) hook(file, editor);

	public function activeChanged(file:String):Void
		for (hook in activeHooks.copy()) hook(file);

	public function navigated():Void
		for (hook in navigationHooks.copy()) hook();

	public function edited(file:String):Void
		for (hook in editedHooks.copy()) hook(file);

	public function frame():Void
		for (hook in frameHooks.copy()) hook();

	public function retained():Array<String> {
		var out:Array<String> = [];
		for (files in retainers) out = out.concat(files());
		return out;
	}

	/** The reason `path` may not be `doing`, or null. */
	public function refusal(path:String, doing:String):Null<String> {
		for (check in refusals) {
			var why = check(path, doing);
			if (why != null) return why;
		}
		return null;
	}

	public function closing():Void
		for (hook in closeHooks.copy()) hook();
}
