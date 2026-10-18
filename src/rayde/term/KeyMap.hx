package rayde.term;

import window.Key;
import window.NamedKey;

/**
 * What a key sends a program on a terminal: the bytes xterm sends. A letter
 * with Ctrl is its control code, Alt puts an escape before it, the arrows and
 * the keys around them send their sequences, with the modifiers in them when
 * there are any, and the arrows send the application form while a program asks
 * for it.
 */
class KeyMap {
	/** The text to write for `key` with the modifiers held, or null for a key that sends nothing. */
	public static function encode(key:Key, shift:Bool, control:Bool, alt:Bool, application:Bool):Null<String> {
		return switch key {
			case Named(n): named(n, shift, control, alt, application);
			case Character(text): character(text, control, alt);
			case _: null;
		}
	}

	static function character(text:String, control:Bool, alt:Bool):Null<String> {
		if (text == "")
			return null;
		if (control) {
			if (text.length != 1)
				return null;
			var c = text.toLowerCase().charCodeAt(0);
			if (c >= "a".code && c <= "z".code)
				return String.fromCharCode(c - 96) ;
			return switch text {
				case "@" | " " | "2": "\x00";
				case "[" | "3": "\x1b";
				case "\\" | "4": "\x1c";
				case "]" | "5": "\x1d";
				case "^" | "6": "\x1e";
				case "_" | "/" | "7": "\x1f";
				case "?" | "8": "\x7f";
				case _: null;
			}
		}
		return alt ? "\x1b" + text : text;
	}

	/** The modifier number xterm puts in a sequence: 1 plus Shift 1, Alt 2, Control 4. */
	static function modifier(shift:Bool, control:Bool, alt:Bool):Int
		return 1 + (shift ? 1 : 0) + (alt ? 2 : 0) + (control ? 4 : 0);

	/** An arrow or Home or End: `ESC [ letter`, `ESC O letter` for a program in application mode, `ESC [ 1 ; mod letter` with modifiers. */
	static function cursor(letter:String, shift:Bool, control:Bool, alt:Bool, application:Bool):String {
		var m = modifier(shift, control, alt);
		return m > 1 ? "\x1b[1;" + m + letter : (application ? "\x1bO" : "\x1b[") + letter;
	}

	/** A key sent as `ESC [ code ~`, with the modifier before the tilde when there is one. */
	static function tilde(code:Int, shift:Bool, control:Bool, alt:Bool):String {
		var m = modifier(shift, control, alt);
		return "\x1b[" + code + (m > 1 ? ";" + m : "") + "~";
	}

	/** F1 to F4: `ESC O letter`, or `ESC [ 1 ; mod letter` with modifiers. */
	static function function1(letter:String, shift:Bool, control:Bool, alt:Bool):String {
		var m = modifier(shift, control, alt);
		return m > 1 ? "\x1b[1;" + m + letter : "\x1bO" + letter;
	}

	static function named(n:NamedKey, shift:Bool, control:Bool, alt:Bool, application:Bool):Null<String> {
		return switch n {
			case Enter: alt ? "\x1b\r" : "\r";
			case Tab: shift ? "\x1b[Z" : alt ? "\x1b\t" : "\t";
			case Space: control ? "\x00" : alt ? "\x1b " : " ";
			case Backspace: control ? "\x08" : alt ? "\x1b\x7f" : "\x7f";
			case Escape: "\x1b";
			case ArrowUp: cursor("A", shift, control, alt, application);
			case ArrowDown: cursor("B", shift, control, alt, application);
			case ArrowRight: cursor("C", shift, control, alt, application);
			case ArrowLeft: cursor("D", shift, control, alt, application);
			case Home: cursor("H", shift, control, alt, application);
			case End: cursor("F", shift, control, alt, application);
			case Insert: tilde(2, shift, control, alt);
			case Delete: tilde(3, shift, control, alt);
			case PageUp: tilde(5, shift, control, alt);
			case PageDown: tilde(6, shift, control, alt);
			case F1: function1("P", shift, control, alt);
			case F2: function1("Q", shift, control, alt);
			case F3: function1("R", shift, control, alt);
			case F4: function1("S", shift, control, alt);
			case F5: tilde(15, shift, control, alt);
			case F6: tilde(17, shift, control, alt);
			case F7: tilde(18, shift, control, alt);
			case F8: tilde(19, shift, control, alt);
			case F9: tilde(20, shift, control, alt);
			case F10: tilde(21, shift, control, alt);
			case F11: tilde(23, shift, control, alt);
			case F12: tilde(24, shift, control, alt);
			case _: null;
		}
	}

	/** A press of mouse button `button` (0 left, 1 middle, 2 right, 64 and 65 the wheel) at 1-based `col` and `row`, as the program asked to have it. */
	public static function mouse(button:Int, col:Int, row:Int, release:Bool, encoding:Int):Null<String> {
		if (encoding == 2)
			return "\x1b[<" + button + ";" + col + ";" + row + (release ? "m" : "M");
		if (col > 222 || row > 222)
			return null;
		var code = release ? 3 : button;
		return "\x1b[M" + String.fromCharCode(32 + code) + String.fromCharCode(32 + col) + String.fromCharCode(32 + row);
	}
}
