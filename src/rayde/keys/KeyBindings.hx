package rayde.keys;

import rayde.settings.Store;

using StringTools;

/** The keys a command has, and where they come from: the defaults, or a change the user made. */
typedef Binding = {command:String, chord:Null<Chord>, user:Bool};

/**
 * Which key does which command. Each command has at most one key: the one its keymap gives it (the keymap of
 * an editor people know, VS Code's unless another is chosen), or the one the user chose, which is kept in
 * `.rayde/keybindings.json` as a list of `{"command": ..., "key": ...}`, a key of "" taking the command's key
 * away. The keymap is the `keymap` section of `.rayde/settings.json`; the user's own changes stay on top of it. Keys are chords as `Chord.parse` reads them, with `mod` for Command or Control.
 * The same key on two commands is allowed and shown as a conflict; the first command in the list runs.
 */
class KeyBindings {
	public final mac:Bool;

	/** What the user changed, by command: a chord, or null for a key taken away. */
	final changes = new Map<String, Null<Chord>>();

	/** The commands the user changed, in the order they did it. */
	final order:Array<String> = [];

	/** The id of the keymap in use. */
	public var preset(default, null) = Keymaps.DEFAULT;

	var base = new Map<String, Chord>();

	/** The commands that have a key, in listing order, and the chord text each is found by. */
	var index = new Map<String, String>();

	public function new(mac:Bool, preset = Keymaps.DEFAULT) {
		this.mac = mac;
		use(preset);
		rebuild();
	}

	/** Takes the keys of the keymap `id`, the default when there is none of that name. */
	function use(id:String):Void {
		var map = Keymaps.find(id);
		preset = map.id;
		base = new Map();
		for (e in map.keys) {
			var text = Keymaps.key(map, e.command, mac), chord = text == null ? null : Chord.parse(text, mac);
			if (chord != null)
				base.set(e.command, chord);
		}
	}

	/**
	 * Changes the keymap. What the user changed stays, except a change that now says what the keymap does,
	 * which is no change.
	 */
	public function setPreset(id:String):Void {
		use(id);
		for (c in order.copy())
			put(c, changes.get(c));
		rebuild();
	}

	static function file(root:String):String
		return haxe.io.Path.join([root, ".rayde", "keybindings.json"]);

	/** The bindings for the project at `root`: its keymap, with the user's changes on top when the file holds any. */
	public static function read(root:String, mac:Bool):KeyBindings {
		var chosen = Store.section(root, "keymap").preset;
		var k = new KeyBindings(mac, chosen == null ? Keymaps.DEFAULT : Std.string(chosen));
		try {
			if (sys.FileSystem.exists(file(root))) {
				var json:Dynamic = haxe.Json.parse(sys.io.File.getContent(file(root)));
				if (Std.isOfType(json, Array))
					for (entry in (json : Array<Dynamic>)) {
						if (entry == null || entry.command == null || entry.key == null)
							continue;
						var text = Std.string(entry.key).trim();
						var chord = text == "" ? null : Chord.parse(text, mac);
						if (text == "" || chord != null)
							k.put(Std.string(entry.command), chord);
					}
			}
		} catch (_:Dynamic) {}
		k.rebuild();
		return k;
	}

	public function save(root:String):Void {
		Store.save(root, "keymap", {preset: preset});
		saveChanges(root);
	}

	function saveChanges(root:String):Void
		try {
			var dir = haxe.io.Path.join([root, ".rayde"]);
			if (changes.keys().hasNext()) {
				if (!sys.FileSystem.exists(dir))
					sys.FileSystem.createDirectory(dir);
				var out = [for (c in order) {command: c, key: changes.get(c) == null ? "" : changes.get(c).toString()}];
				sys.io.File.saveContent(file(root), haxe.Json.stringify(out, null, "\t") + "\n");
			} else if (sys.FileSystem.exists(file(root)))
				sys.FileSystem.deleteFile(file(root));
		} catch (_:Dynamic) {}

	function put(command:String, chord:Null<Chord>):Void {
		// A change that puts a command back where it was is not a change.
		if (base.exists(command) ? chord != null && chord.equals(base.get(command)) : chord == null) {
			changes.remove(command);
			order.remove(command);
			return;
		}
		if (!changes.exists(command))
			order.push(command);
		changes.set(command, chord);
	}

	/** The key `command` has now, or null. */
	public function of(command:String):Null<Chord>
		return changes.exists(command) ? changes.get(command) : base.get(command);

	/** Whether the user changed `command`'s key. */
	public function changed(command:String):Bool
		return changes.exists(command);

	/** Whether any command has a key the user changed. */
	public function anyChanged():Bool
		return changes.keys().hasNext();

	/** Gives `command` the key `chord`, or takes its key away with null. */
	public function set(command:String, chord:Null<Chord>):Void {
		put(command, chord);
		rebuild();
	}

	/** Puts `command`'s key back to its default. */
	public function reset(command:String):Void {
		changes.remove(command);
		order.remove(command);
		rebuild();
	}

	public function resetAll():Void {
		for (c in order.copy())
			changes.remove(c);
		order.resize(0);
		rebuild();
	}

	/** The commands, other than `command`, that have the same key. */
	public function conflicts(command:String):Array<String> {
		var chord = of(command);
		if (chord == null)
			return [];
		return [for (c in commandsWithKeys()) if (c != command && chord.equals(of(c))) c];
	}

	/** The command a press of `chord` runs, or null. */
	public function commandFor(chord:Chord):Null<String>
		return index.get(chord.toString());

	/** Whether `command` has a key in the keymap in use, whatever the user changed. */
	public function inKeymap(command:String):Bool
		return base.exists(command);

	/** The label of `command`'s key as the page and the menus show it, or null when it has none. */
	public function label(command:String):Null<String> {
		var chord = of(command);
		return chord == null ? null : chord.label(mac);
	}

	function commandsWithKeys():Array<String> {
		var out = Keymaps.order.copy();
		for (c in order)
			if (out.indexOf(c) < 0)
				out.push(c);
		return [for (c in out) if (of(c) != null) c];
	}

	function rebuild():Void {
		index = new Map();
		for (c in commandsWithKeys()) {
			var text = of(c).toString();
			if (!index.exists(text))
				index.set(text, c);
		}
	}
}
