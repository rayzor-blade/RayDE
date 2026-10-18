package rayde.ext;

/** An editor event an extension can listen for: its name, what a handler is called with, and when it is sent. */
typedef HookInfo = {name:String, data:String, detail:String};

/** A menu an extension can add items to, by the location its config names. */
typedef MenuLocation = {id:String, label:String, detail:String};

/** What an extension can hook into: the events RayDE sends and the menus it lets an extension add to. */
class Hooks {
	/** Events, for `onHook(name, handler)`. An event the extension listens for is sent to it; the rest are not. */
	public static final events:Array<HookInfo> = [
		{name: "project.opened", data: "{ root }", detail: "Project folder. Sent once, when the extension subscribes"},
		{name: "active.changed", data: "{ path }", detail: "Editor in front changed; path is null for a page that is not a file. Sent on subscribe"},
		{name: "file.opened", data: "{ path }", detail: "Editor tab opened for a file"},
		{name: "file.closed", data: "{ path }", detail: "Editor tab closed"},
		{name: "file.changed", data: "{ path }", detail: "Buffer edited. Repeats within 300 ms collapse into one call per file"},
		{name: "file.saved", data: "{ path }", detail: "Buffer written to disk"}
	];

	/** Menus, for `contributes.menus`. An item runs its command with `{ path, kind }` of what the menu was opened on. */
	public static final menus:Array<MenuLocation> = [
		{id: "explorer/context", label: "Explorer context menu", detail: "Files and folders in the Explorer"},
		{id: "editor/title", label: "Editor title menu", detail: "The editor's actions menu, for the file in front"}
	];

	public static function knownEvent(name:String):Bool
		return Lambda.exists(events, e -> e.name == name);

	public static function knownMenu(id:String):Bool
		return Lambda.exists(menus, m -> m.id == id);

	public static function eventNames():Array<String>
		return [for (e in events) e.name];

	public static function menuIds():Array<String>
		return [for (m in menus) m.id];
}
