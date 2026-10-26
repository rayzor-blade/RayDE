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

#if (wasm || rayde_page)
typedef Terminal = RemoteTerminal;
#else
typedef Terminal = NativeTerminal;
#end
