package rayde.keys;

/** The key a keymap gives a command: `key` as chord text, or on a Mac `mac` when that is given. An empty key is none. */
typedef Key = {command:String, key:String, ?mac:String};

/**
 * The keys of another editor, by the name it is known by. `platform` limits where it is offered: `mac` for an
 * editor that exists only there, `other` for one that does not exist on a Mac, empty for both.
 */
typedef Keymap = {id:String, label:String, note:String, platform:String, keys:Array<Key>};

/**
 * Keymaps for the commands RayDE has, as the editors people know bind them. A command an editor has no key for
 * has none here, and a command RayDE has that the editor lacks keeps none. `mod` is Command on a Mac and Control
 * elsewhere. Chord sequences, such as Sublime's and VS Code's Cmd+K Cmd+S, are not expressible, so those commands
 * go without a key.
 */
class Keymaps {
	public static inline var DEFAULT = "vscode";

	/** The commands that can have a key, in the order a key shared by two of them is settled: the first runs. */
	public static final order = [
		"newwindow", "closewindow", "quickopen", "commands", "gotoline", "find", "replace", "findnext", "findprevious", "buildproject", "run", "stop", "save", "close", "definition", "suggest", "parameterhints", "panel", "explorer", "problems", "output", "terminal", "newterminal",
		"splitterminal", "settings", "minimize", "fullscreen", "togglebreakpoint", "pause", "stepover", "stepinto", "stepout", "filerename", "filedelete", "filecopy", "filecut", "filepaste", "fileduplicate", "filecopypath", "filereveal"
	];

	/** The commands that act on the file or folder selected in the Explorer, which run only while the Explorer has the keyboard. */
	public static final fileCommands = [
		"filerename", "filedelete", "filecopy", "filecut", "filepaste", "fileduplicate", "filecopypath", "filecopyrelative", "filereveal", "newfile", "newfolder"
	];

	/** The keys of the Explorer's file commands: the clipboard and delete as every editor has them, and `rename` as this one does. */
	static function files(rename:String, ?copyPath:Key, ?reveal:Key):Array<Key>
		return [
			k("filerename", rename), k("filedelete", "delete", "cmd+backspace"), k("filecopy", "mod+c"), k("filecut", "mod+x"), k("filepaste", "mod+v"),
			k("fileduplicate", "mod+d"), copyPath == null ? k("filecopypath", "") : copyPath, reveal == null ? k("filereveal", "") : reveal
		];

	static function k(command:String, key:String, ?mac:String):Key
		return {command: command, key: key, mac: mac};

	public static final all:Array<Keymap> = [
		{
			id: "vscode",
			label: "Visual Studio Code",
			note: "RayDE's own: quick open, the command palette and the panel toggles as in VS Code.",
			platform: "",
			keys: [
				k("buildproject", "mod+shift+b"),
				k("newwindow", "mod+shift+n"), k("closewindow", "mod+shift+w"), k("quickopen", "mod+p"), k("commands", "mod+shift+p"), k("gotoline", "ctrl+g"), k("find", "mod+f"), k("replace", "ctrl+h", "alt+cmd+f"), k("findnext", "f3", "cmd+g"), k("findprevious", "shift+f3", "shift+cmd+g"), k("run", "f5"), k("stop", "shift+f5"), k("save", "mod+s"),
				k("close", "mod+w"), k("definition", "f12"), k("suggest", "ctrl+space"), k("parameterhints", "mod+shift+space"), k("panel", "mod+j"), k("explorer", "mod+b"), k("problems", "mod+shift+m"), k("output", "mod+shift+u"),
				k("terminal", "ctrl+`"), k("newterminal", "ctrl+shift+`"), k("splitterminal", "ctrl+shift+5", "mod+\\"), k("settings", "mod+,"),
				k("minimize", "", "cmd+m"), k("fullscreen", "alt+shift+enter", "ctrl+cmd+f"), k("togglebreakpoint", "f9"), k("pause", "f6"), k("stepover", "f10"),
				k("stepinto", "f11"), k("stepout", "shift+f11")
			].concat(files("f2", k("filecopypath", "shift+alt+c", "alt+cmd+c"), k("filereveal", "shift+alt+r", "alt+cmd+r")))
		},
		{
			id: "intellij",
			label: "IntelliJ IDEA",
			note: "JetBrains IDEs: Find Action, Go to Declaration, tool windows on the number keys.",
			platform: "",
			keys: [
				k("quickopen", "ctrl+shift+n", "cmd+shift+o"), k("commands", "ctrl+shift+a", "cmd+shift+a"), k("gotoline", "ctrl+g", "cmd+l"),
				k("find", "mod+f"), k("replace", "ctrl+r", "cmd+r"), k("findnext", "f3", "cmd+g"), k("findprevious", "shift+f3", "shift+cmd+g"),
				k("run", "shift+f10", "ctrl+r"), k("stop", "ctrl+f2", "cmd+f2"), k("save", "mod+s"), k("close", "ctrl+f4", "cmd+w"), k("definition", "ctrl+b", "cmd+b"), k("suggest", "ctrl+space"),
				k("panel", "ctrl+shift+f12", "cmd+shift+f12"), k("explorer", "alt+1", "cmd+1"), k("problems", "alt+6", "cmd+6"), k("output", "alt+4", "cmd+4"),
				k("terminal", "alt+f12"), k("settings", "ctrl+alt+s", "cmd+,")
			].concat(files("shift+f6"))
		},
		{
			id: "sublime",
			label: "Sublime Text",
			note: "Go to Anything, the command palette and Build.",
			platform: "",
			keys: [
				k("quickopen", "mod+p"), k("commands", "mod+shift+p"), k("gotoline", "ctrl+g"), k("run", "mod+b"), k("save", "ctrl+shift+s", "cmd+alt+s"),
				k("find", "mod+f"), k("replace", "ctrl+h", "alt+cmd+f"), k("findnext", "f3", "cmd+g"), k("findprevious", "shift+f3", "shift+cmd+g"),
				k("close", "mod+w"), k("definition", "f12"), k("suggest", "ctrl+space"), k("settings", "", "cmd+,")
			].concat(files("f2"))
		},
		{
			id: "eclipse",
			label: "Eclipse",
			note: "Open Resource, Quick Access and Open Declaration.",
			platform: "",
			keys: [
				k("quickopen", "mod+shift+r"), k("commands", "mod+3"), k("gotoline", "mod+l"), k("run", "ctrl+f11", "cmd+shift+f11"), k("stop", "mod+f2"),
				k("find", "mod+f"), k("replace", ""), k("findnext", "mod+k"), k("findprevious", "mod+shift+k"),
				k("save", "mod+shift+s"), k("close", "mod+w"), k("definition", "f3"), k("suggest", "ctrl+space"), k("parameterhints", "ctrl+shift+space"), k("settings", "", "cmd+,")
			].concat(files("f2"))
		},
		{
			id: "visualstudio",
			label: "Visual Studio",
			note: "Go To All, Start Debugging and Solution Explorer.",
			platform: "other",
			keys: [
				k("quickopen", "ctrl+t"), k("commands", "ctrl+q"), k("gotoline", "ctrl+g"), k("run", "f5"), k("stop", "shift+f5"), k("save", "ctrl+shift+s"),
				k("find", "ctrl+f"), k("replace", "ctrl+h"), k("findnext", "f3"), k("findprevious", "shift+f3"),
				k("close", "ctrl+f4"), k("definition", "f12"), k("suggest", "ctrl+space"), k("parameterhints", "ctrl+shift+space"), k("explorer", "ctrl+alt+l"), k("output", "ctrl+alt+o"), k("terminal", "ctrl+`")
			].concat(files("f2"))
		},
		{
			id: "xcode",
			label: "Xcode",
			note: "Open Quickly, Run and Stop, and the navigator on Cmd+0.",
			platform: "mac",
			keys: [
				k("quickopen", "cmd+shift+o"), k("commands", "cmd+shift+a"), k("gotoline", "cmd+l"), k("run", "cmd+r"), k("stop", "cmd+."), k("save", "cmd+alt+s"),
				k("find", "cmd+f"), k("replace", "alt+cmd+f"), k("findnext", "cmd+g"), k("findprevious", "shift+cmd+g"),
				k("close", "cmd+w"), k("definition", "ctrl+cmd+j"), k("suggest", "ctrl+space"), k("settings", "cmd+,"), k("explorer", "cmd+0"), k("panel", "cmd+shift+y")
			].concat(files("f2"))
		}
	];

	/** The keymap named `id`, or the default when there is none of that name. */
	public static function find(id:Null<String>):Keymap {
		var found = Lambda.find(all, m -> m.id == id);
		return found == null ? all[0] : found;
	}

	/** The keymaps that exist where the program runs. */
	public static function available(mac:Bool):Array<Keymap>
		return [for (m in all) if (m.platform == "" || m.platform == (mac ? "mac" : "other")) m];

	/** The chord text `keymap` gives `command` here, or null. */
	public static function key(keymap:Keymap, command:String, mac:Bool):Null<String> {
		var entry = Lambda.find(keymap.keys, e -> e.command == command);
		if (entry == null)
			return null;
		var text = mac && entry.mac != null ? entry.mac : entry.key;
		return text == "" ? null : text;
	}
}
