import rayde.keys.Chord;

/** Run with haxe -cp src -cp ../hlwindow/haxe -cp tests/web -main ShortcutLabels --interp. */
class ShortcutLabels {
	static function main():Void {
		for (mac in [true, false]) {
			var quick = Chord.parse("mod+p", mac), commands = Chord.parse("mod+shift+p", mac);
			if (quick.keycaps(mac).join("|") != (mac ? "⌘|P" : "Ctrl|P")) throw "quick-open keycaps";
			if (commands.keycaps(mac).join("|") != (mac ? "⇧|⌘|P" : "Ctrl|Shift|P")) throw "command keycaps";
			if (commands.label(mac) != (mac ? "⇧⌘P" : "Ctrl+Shift+P")) throw "command shortcut label";
			if (quick.meta != mac || quick.ctrl == mac) throw "shortcut modifier binding";
			if (Chord.parse("mod+enter", mac).label(mac) != (mac ? "⌘↩" : "Ctrl+Enter")) throw "editing key label";
		}
		Sys.println("shortcut labels and bindings follow the visitor platform");
	}
}
