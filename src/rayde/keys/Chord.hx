package rayde.keys;

import window.Key;
import window.NamedKey;

using StringTools;

/**
 * One press of a key with the modifiers held, which a key binding is made of. The key is a lowercase
 * name: a letter, digit or symbol as typed without Shift, or `enter`, `escape`, `tab`, `space`, `up`,
 * `down`, `left`, `right`, `home`, `end`, `pageup`, `pagedown`, `backspace`, `delete`, `insert`, `f1` to `f20`.
 */
class Chord {
	public final key:String;
	public final ctrl:Bool;
	public final alt:Bool;
	public final shift:Bool;
	/** Command on a Mac, the Windows key elsewhere. */
	public final meta:Bool;

	static final named = [
		"enter" => "Enter", "escape" => "Esc", "tab" => "Tab", "space" => "Space", "backspace" => "Backspace", "delete" => "Delete", "insert" => "Insert",
		"home" => "Home", "end" => "End", "pageup" => "Page Up", "pagedown" => "Page Down", "up" => "Up", "down" => "Down", "left" => "Left", "right" => "Right"
	];
	static final arrows = ["up" => "↑", "down" => "↓", "left" => "←", "right" => "→"];

	/** The keys a Mac's menus draw as symbols. */
	static final glyphs = ["backspace" => "⌫", "delete" => "⌦", "enter" => "↩", "escape" => "⎋", "tab" => "⇥"];

	/** What Shift makes of a symbol on a US keyboard, so a chord is the same however it was typed. */
	static final shifted = [
		"~" => "`", "!" => "1", "@" => "2", "#" => "3", "$" => "4", "%" => "5", "^" => "6", "&" => "7", "*" => "8", "(" => "9", ")" => "0", "_" => "-", "+" => "=",
		"{" => "[", "}" => "]", "|" => "\\", ":" => ";", "\"" => "'", "<" => ",", ">" => ".", "?" => "/"
	];

	public function new(key:String, ctrl = false, alt = false, shift = false, meta = false) {
		this.key = key;
		this.ctrl = ctrl;
		this.alt = alt;
		this.shift = shift;
		this.meta = meta;
	}

	/**
	 * A chord from text such as `mod+shift+p` or `ctrl+``: modifiers, then the key, joined by +. `mod` is
	 * Command on a Mac and Control elsewhere. Null when the text names no key or a modifier twice.
	 */
	public static function parse(text:String, mac:Bool):Null<Chord> {
		var ctrl = false, alt = false, shift = false, meta = false, key:Null<String> = null;
		var parts = text.trim().split("+");
		// "ctrl++" is Control and the plus key: two empty parts at the end stand for the key itself.
		if (parts.length >= 2 && parts[parts.length - 1] == "" && parts[parts.length - 2] == "") {
			parts = parts.slice(0, parts.length - 2);
			parts.push("+");
		}
		for (i => raw in parts) {
			var part = raw.trim().toLowerCase();
			if (part == "")
				return null;
			var last = i == parts.length - 1;
			switch part {
				case "mod" if (!last):
					if (mac ? meta : ctrl)
						return null;
					if (mac)
						meta = true;
					else
						ctrl = true;
				case "cmd" | "command" | "super" | "meta" | "win" if (!last):
					if (meta)
						return null;
					meta = true;
				case "ctrl" | "control" if (!last):
					if (ctrl)
						return null;
					ctrl = true;
				case "alt" | "option" | "opt" if (!last):
					if (alt)
						return null;
					alt = true;
				case "shift" if (!last):
					if (shift)
						return null;
					shift = true;
				case _:
					if (!last || modifierNames.indexOf(part) >= 0)
						return null;
					key = normalise(part);
			}
		}
		if (key == null || !validKey(key))
			return null;
		if (shifted.exists(key)) {
			key = shifted.get(key);
			shift = true;
		}
		return new Chord(key, ctrl, alt, shift, meta);
	}

	static final modifierNames = ["mod", "cmd", "command", "super", "meta", "win", "ctrl", "control", "alt", "option", "opt", "shift"];

	static function validKey(key:String):Bool
		return key.length == 1 || named.exists(key) || ~/^f([1-9]|1[0-9]|20)$/.match(key);

	static function normalise(part:String):String
		return switch part {
			case "esc": "escape";
			case "return": "enter";
			case "del": "delete";
			case "ins": "insert";
			case "pgup": "pageup";
			case "pgdn": "pagedown";
			case "arrowup": "up";
			case "arrowdown": "down";
			case "arrowleft": "left";
			case "arrowright": "right";
			case "plus": "+";
			case _: part;
		}

	/** The chord a key press makes, or null for a modifier alone and for a key a binding cannot name. */
	public static function ofEvent(key:Key, shift:Bool, ctrl:Bool, alt:Bool, meta:Bool):Null<Chord> {
		switch key {
			case Named(n):
				var name = switch n {
					case Enter: "enter";
					case Escape: "escape";
					case Tab: "tab";
					case Space: "space";
					case Backspace: "backspace";
					case Delete: "delete";
					case Insert: "insert";
					case Home: "home";
					case End: "end";
					case PageUp: "pageup";
					case PageDown: "pagedown";
					case ArrowUp: "up";
					case ArrowDown: "down";
					case ArrowLeft: "left";
					case ArrowRight: "right";
					case _:
						var code:Int = n;
						code >= (NamedKey.F1 : Int) && code <= (NamedKey.F20 : Int) ? "f" + (code - (NamedKey.F1 : Int) + 1) : null;
				}
				return name == null ? null : new Chord(name, ctrl, alt, shift, meta);
			case Character(text):
				if (text == "")
					return null;
				if (text == " ")
					return new Chord("space", ctrl, alt, shift, meta);
				var base = text.toLowerCase(), pressed = shift;
				if (shifted.exists(base)) {
					base = shifted.get(base);
					pressed = true;
				}
				return base.length == 1 ? new Chord(base, ctrl, alt, pressed, meta) : null;
			case _:
				return null;
		}
	}

	/** The text a keybindings file holds: modifiers in the order ctrl, alt, shift, cmd, then the key. */
	public function toString():String {
		var out = [];
		if (ctrl)
			out.push("ctrl");
		if (alt)
			out.push("alt");
		if (shift)
			out.push("shift");
		if (meta)
			out.push("cmd");
		out.push(key);
		return out.join("+");
	}

	/** How a menu or the Settings page shows it: ⌃⇧⌘P on a Mac, Ctrl+Shift+P elsewhere. */
	public function label(mac:Bool):String {
		var name = named.exists(key) ? named.get(key) : key.toUpperCase();
		if (mac) {
			var symbols = (ctrl ? "⌃" : "") + (alt ? "⌥" : "") + (shift ? "⇧" : "") + (meta ? "⌘" : "");
			return symbols + (arrows.exists(key) ? arrows.get(key) : glyphs.exists(key) ? glyphs.get(key) : name);
		}
		return (ctrl ? "Ctrl+" : "") + (alt ? "Alt+" : "") + (shift ? "Shift+" : "") + (meta ? "Win+" : "") + name;
	}

	public function equals(other:Null<Chord>):Bool
		return other != null && key == other.key && ctrl == other.ctrl && alt == other.alt && shift == other.shift && meta == other.meta;

	/** Whether any modifier is held: a chord of a plain letter would be typed text. */
	public function modified():Bool
		return ctrl || alt || meta;
}
