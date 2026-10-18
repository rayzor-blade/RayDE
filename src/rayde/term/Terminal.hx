package rayde.term;

/** A run of equally styled text on one row of the screen: where it starts and how many cells it covers, how it is set, and what it says. */
typedef Run = {
	col:Int,
	cells:Int,
	/** Bold 1, italic 2, underline 4, inverse 8. */
	attrs:Int,
	/** 0 for the default, 1<<24 | palette index, or 2<<24 | rgb. */
	fg:Int,
	bg:Int,
	text:String
};

/** What the screen is doing besides its rows. */
typedef Screen = {
	rows:Int,
	cols:Int,
	cursorRow:Int,
	cursorColumn:Int,
	cursorShown:Bool,
	/** Arrow keys send application sequences. */
	applicationCursor:Bool,
	/** Pasted text is wrapped so the program can tell it from typing. */
	bracketedPaste:Bool,
	alternate:Bool,
	/** 0 none, 1 press, 2 press and release, 3 button motion, 4 any motion. */
	mouseMode:Int,
	/** 0 default, 1 utf-8, 2 sgr. */
	mouseEncoding:Int,
	/** How many lines back the view is, 0 when it follows the program. */
	scrollback:Int
};

/**
 * A program on a pseudo-terminal, and the screen it draws. The work is in a
 * native library: it runs the program, reads what it prints into a terminal
 * emulator, and keeps the screen's cells, so this side asks which rows changed
 * and fetches those as runs, a few objects a row and none a cell.
 */
class Terminal {
	public final handle:Int;

	/** The program run, a shell unless one was named. */
	public final program:String;

	var closed = false;

	function new(handle:Int, program:String) {
		this.handle = handle;
		this.program = program;
	}

	/** Runs `program` (the user's shell when empty) with `args` (a login shell when empty) in `cwd`, on a screen of `cols` by `rows`; null when it could not start. */
	public static function open(cols:Int, rows:Int, ?cwd:String, ?program:String, ?args:Array<String>):Null<Terminal> {
		var c = bytes(cwd), p = bytes(program), a = bytes(args == null ? null : args.join("\x1f"));
		var handle = openNative(cols, rows, c.data, c.length, p.data, p.length, a.data, a.length);
		return handle < 0 ? null : new Terminal(handle, program == null || program == "" ? "shell" : program);
	}

	static function bytes(text:Null<String>):{data:hl.Bytes, length:Int} {
		if (text == null || text == "")
			return {data: null, length: 0};
		var b = haxe.io.Bytes.ofString(text);
		return {data: b.getData(), length: b.length};
	}

	/** Types `text` into the program, as the keyboard would. */
	public function write(text:String):Bool {
		var b = bytes(text);
		return !closed && b.length > 0 && writeNative(handle, b.data, b.length) == 1;
	}

	public function resize(cols:Int, rows:Int):Void
		if (!closed)
			resizeNative(handle, cols, rows);

	/** A number that changes whenever the screen does. */
	public function revision():Int
		return closed ? 0 : revisionNative(handle);

	/** -1 while the program runs, else the code it exited with. */
	public function exitCode():Int
		return closed ? -3 : exitNative(handle);

	public function screen():Screen {
		var b = closed ? null : infoNative(handle);
		if (b == null)
			return {rows: 0, cols: 0, cursorRow: 0, cursorColumn: 0, cursorShown: false, applicationCursor: false, bracketedPaste: false, alternate: false, mouseMode: 0, mouseEncoding: 0, scrollback: 0};
		var flags = b.getUI8(8);
		return {
			rows: b.getUI16(0),
			cols: b.getUI16(2),
			cursorRow: b.getUI16(4),
			cursorColumn: b.getUI16(6),
			cursorShown: flags & 1 != 0,
			applicationCursor: flags & 2 != 0,
			bracketedPaste: flags & 4 != 0,
			alternate: flags & 8 != 0,
			mouseMode: b.getUI8(9),
			mouseEncoding: b.getUI8(10),
			scrollback: b.getUI16(12)
		};
	}

	/** The rows that changed since this was last asked, the first time all of them. */
	public function dirtyRows():Array<Int> {
		var b = closed ? null : dirtyNative(handle);
		if (b == null)
			return [];
		var rows = screen().rows;
		return [for (i in 0...rows) if (b.getUI8(i) != 0) i];
	}

	/** Row `row` of the screen as runs of styled text; blank cells have none. */
	public function row(row:Int):Array<Run> {
		var b = closed ? null : rowNative(handle, row);
		if (b == null)
			return [];
		var length = b.getI32(0), at = 4, out = [];
		while (at < 4 + length) {
			var size = b.getUI16(at + 13);
			out.push({
				col: b.getUI16(at),
				cells: b.getUI16(at + 2),
				attrs: b.getUI8(at + 4),
				fg: b.getI32(at + 5),
				bg: b.getI32(at + 9),
				text: size == 0 ? "" : b.sub(at + 15, size).toBytes(size).toString()
			});
			at += 15 + size;
		}
		return out;
	}

	/** The text of row `row` as one line, for tests and for copying a line. */
	public function line(row:Int):String {
		var out = new StringBuf(), at = 0;
		for (run in this.row(row)) {
			while (at < run.col) {
				out.add(" ");
				at++;
			}
			out.add(run.text);
			at = run.col + run.cells;
		}
		return out.toString();
	}

	/** Shows the screen `lines` back in the program's output, or the live screen at 0; how far back it could go. */
	public function scrollback(lines:Int):Int
		return closed ? 0 : scrollbackNative(handle, lines);

	/** The text between two cells of the screen, for copying. */
	public function text(row1:Int, col1:Int, row2:Int, col2:Int):String {
		var b = closed ? null : textNative(handle, row1, col1, row2, col2);
		if (b == null)
			return "";
		var length = b.getI32(0);
		return length == 0 ? "" : b.sub(4, length).toBytes(length).toString();
	}

	/** Ends the program and frees the screen. */
	public function close():Void {
		if (!closed)
			closeNative(handle);
		closed = true;
	}

	@:hlNative("cterm", "term_open") static function openNative(cols:Int, rows:Int, cwd:hl.Bytes, cwdLength:Int, program:hl.Bytes, programLength:Int, args:hl.Bytes, argsLength:Int):Int
		return -1;

	@:hlNative("cterm", "term_write") static function writeNative(handle:Int, data:hl.Bytes, length:Int):Int
		return 0;

	@:hlNative("cterm", "term_resize") static function resizeNative(handle:Int, cols:Int, rows:Int):Int
		return 0;

	@:hlNative("cterm", "term_revision") static function revisionNative(handle:Int):Int
		return 0;

	@:hlNative("cterm", "term_exit") static function exitNative(handle:Int):Int
		return -3;

	@:hlNative("cterm", "term_info") static function infoNative(handle:Int):hl.Bytes
		return null;

	@:hlNative("cterm", "term_dirty") static function dirtyNative(handle:Int):hl.Bytes
		return null;

	@:hlNative("cterm", "term_row") static function rowNative(handle:Int, row:Int):hl.Bytes
		return null;

	@:hlNative("cterm", "term_scrollback") static function scrollbackNative(handle:Int, lines:Int):Int
		return 0;

	@:hlNative("cterm", "term_text") static function textNative(handle:Int, row1:Int, col1:Int, row2:Int, col2:Int):hl.Bytes
		return null;

	@:hlNative("cterm", "term_close") static function closeNative(handle:Int):Int
		return 0;
}
