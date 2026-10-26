package rayde.theme;

import ashui.reactive.Signal;
import rayde.settings.Appearance;
import rayde.theme.ThemeFile.Problem;
import rayde.ui.Theming;

/**
 * A `.raytheme` being written. It reads the text of the file as it is in the editor, puts the theme in force in the
 * window after each edit settles, and keeps what is wrong with it. Text that is not a JSON object is a problem and
 * the last theme that read stays in force, so typing through a broken state does not flash the window.
 */
class ThemeStudio {
	/** How long after the last edit the theme is read again, in seconds. */
	static inline var SETTLE = .25;

	public final file:String;

	/** The theme the text read as last, and what is in force: the last one that was readable. */
	public final theme:Signal<ThemeFile>;

	/** Whether the text is unreadable now, so the theme in force is an earlier one. */
	public final stale = Signal.make(false);

	/** What is wrong: the file's problems, then what putting it in force reported (fonts that did not register, CSS the style system warned about). */
	public final problems = Signal.make(([] : Array<Problem>));

	final text:Void->String;
	final write:String->Void;
	final appearance:Void->Appearance;
	final canPreview:Void->Bool;
	var lastEdit = 0.;
	var waiting = false;
	var gone = false;
	var writing = false;

	/**
	 * `text` gives the editor's text of the file, `write` replaces it (and the file), and `appearance` gives the
	 * settings, whose scheme the theme is shown in.
	 */
	public function new(file:String, text:Void->String, write:String->Void, appearance:Void->Appearance, ?canPreview:Void->Bool) {
		this.file = file;
		this.text = text;
		this.write = write;
		this.appearance = appearance;
		this.canPreview = canPreview == null ? () -> true : canPreview;
		theme = Signal.make(ThemeFile.parse(file, text()));
		refresh();
	}

	/** The text changed: the theme is read again once typing pauses. */
	public function edited():Void {
		if (writing) return;
		lastEdit = haxe.Timer.stamp();
		if (waiting || gone)
			return;
		waiting = true;
		ashui.animation.AnimationScheduler.main.after(SETTLE, settle);
	}

	function settle():Void {
		var left = SETTLE - (haxe.Timer.stamp() - lastEdit);
		if (left > 0.001 && !gone) {
			ashui.animation.AnimationScheduler.main.after(left, settle);
			return;
		}
		waiting = false;
		refresh();
	}

	/** Reads the text now and puts the theme in force. */
	public function refresh():Void {
		if (gone)
			return;
		var t = ThemeFile.parse(file, text());
		var found = t.issues.copy();
		if (t.unreadable) {
			stale.set(true);
			problems.set(found);
			return;
		}
		stale.set(false);
		theme.set(t);
		if (canPreview()) {
			var applied = Theming.pin(t, appearance());
			for (f in applied.fonts) found.push({message: f, at: null});
			for (c in applied.css) found.push({message: c, at: "css"});
		}
		problems.set(found);
	}

	/**
	 * Changes the text with `change` (see `ThemeEdit`), writes it, and reads it again at once. A change that cannot be
	 * made, because the text is not a JSON object, is returned as a sentence; null when it was made.
	 */
	public function edit(change:String->String):Null<String> {
		try {
			var next = change(text());
			writing = true;
			write(next);
			writing = false;
		} catch (e:Dynamic) {
			writing = false;
			return Std.string(e);
		}
		refresh();
		return null;
	}

	/** The paths where the text sets the colour `token`, which a reset removes. */
	public function colorPaths(token:String):Array<String> {
		var found = theme.get().placed.get(token);
		return found == null ? [] : found;
	}

	/** Stops reading and puts the chosen theme back. */
	public function dispose():Void {
		gone = true;
		if (Theming.pinned != null && Theming.pinned.file == file) Theming.unpin(appearance());
	}
}
