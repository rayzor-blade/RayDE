package rayde.ui;

import ashui.animation.AnimationScheduler;
import ashui.core.externs.TextNative;
import ashui.draw.DrawContext;
import ashui.input.Clipboard;
import ashui.input.Events.KeyEvent;
import ashui.input.Events.PointerEvent;
import ashui.input.Interaction;
import ashui.input.Pointer;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.theme.ThemeState;
import ashui.types.Brush;
import ashui.types.Color;
import ashui.types.Style;
import ashui.types.Style.FontStyle;
import ashui.types.Style.FontWeight;
import ashui.ui.Component;
import rayde.term.KeyMap;
import rayde.term.Settings;
import rayde.term.Terminal;

typedef TerminalViewProps = {
	terminal:Terminal,
	/** Whether the view is on screen; a terminal that is not is left alone until it is. */
	shown:Void->Bool,
	/** Called once with the exit code when the program ends. */
	?onExit:Int->Void,
	/** Called when the view takes the keyboard, so the workbench knows which terminal is in front. */
	?onFocus:Void->Void,
	/** Whether the workbench takes a key press, which the terminal then leaves alone: the keys that toggle it, and a few more. */
	?reserved:KeyEvent->Bool,
	/** How the cursor is drawn and what a selection does, and a number that changes when they change. */
	?settings:Settings,
	?changes:Signal<Int>
};

/** A run as an element has it: a fresh object each time a row is fetched, so the row's elements are made again. */
private typedef Item = {run:Run};

private typedef RowState = {index:Int, items:Signal<Array<Item>>};

/**
 * A terminal's screen, and the keyboard and pointer for it. Each poll asks the
 * terminal which rows changed and fetches those as runs of styled text; each
 * run is a text element, which the renderer draws from its glyph atlas, and
 * only the rows that changed are made again. A canvas under them draws what is
 * not text: the backgrounds, the selection, underlines and the cursor. What a
 * program prints costs a few elements a row, and an idle terminal costs a poll
 * a tenth of a second. Keys go to the program as
 * `KeyMap` encodes them; the wheel scrolls its output, or goes to the program
 * when it asks for the mouse; a drag selects, and Cmd+C copies what it covers.
 */
class TerminalView extends Component<TerminalViewProps> {
	static inline var PAD = 8.0;


	final revision = Signal.make(0);
	final rowStates = Signal.make(([] : Array<RowState>));

	/** Bumped when the cell's size is known, so the elements are placed by it. */
	final measured = Signal.make(0);

	var cellWidth = 0.;
	var cellHeight = 0.;
	var probe:Element;
	var rows:Array<Array<Run>> = [];
	var screen:Screen;
	var seen = -1;
	var wantCols = 0;
	var wantRows = 0;
	var focused = false;
	var lastOutput = 0.;
	var pollTimer:Null<ashui.animation.AnimationScheduler.Timer>;
	var exited = false;
	final exitCode = Signal.make(-1);
	final launching = Signal.make(false);
	var gone = false;
	var root:Element;
	var anchor:Null<{row:Int, col:Int}> = null;
	var head:Null<{row:Int, col:Int}> = null;
	var drag:Null<LayoutTree->Void> = null;

	function render():Element {
		screen = props.terminal.screen();
		probe = <text id="rayde-terminal-probe" class="rayde-term-text" position={Absolute} left={0} top={0} opacity={0} wrap={false}>M</text>;
		root = <div id="rayde-terminal" class="rayde-terminal relative flex-1 min-h-0 overflow-hidden">
			<canvas position={Absolute} left={0} top={0} widthPercent={1} heightPercent={1} pointerEvents={PointerEvents.None} draw={paint}/>
			${probe}
			<if {launching.get()}><div position={Absolute} left={PAD} top={PAD}><text class="rayde-term-note">Starting terminal…</text></div></if>
			<div position={Absolute} left={PAD} top={PAD / 2} pointerEvents={PointerEvents.None}>
				<for {k in [{rows: rowStates.get(), cell: measured.get()}]}>${rowElements(k.rows)}</for>
			</div>
			<if {exitCode.get() != -1}>
				<div position={Absolute} left={PAD} bottom={6} pointerEvents={PointerEvents.None}><text id="rayde-terminal-exit" class="rayde-term-note">${"[Process exited with code " + exitCode.get() + "]"}</text></div>
			</if>
		</div>;
		var interaction = Interaction.of(root.node).setFocusable(true);
		interaction.onKeyDown(key);
		interaction.onPointerDown(down);
		interaction.onWheel(wheel);
		new ashui.reactive.Watch(() -> interaction.focused.get(), on -> {
			focused = on;
			if (on && props.onFocus != null)
				props.onFocus();
			revision.set(revision.get() + 1);
		});
		// A new theme gives the text its colours again.
		new ashui.reactive.Watch(() -> ThemeState.get().revision.get(), _ -> repaintRows(), (_, _) -> false);
		Owner.onCleanup(() -> {
			gone = true;
			if (pollTimer != null) pollTimer.cancel();
			stopDrag();
		});
		if (props.terminal.remote) {
            var tree = root.tree;
            var hook:LayoutTree->Void = current -> {if (current == tree && !gone) poll();};
            LayoutTree.flushHooks.push(hook);
            new ashui.reactive.Watch(props.shown,on -> props.terminal.setVisible(on));
            Owner.onCleanup(() -> {props.terminal.setVisible(false);for (i in 0...LayoutTree.flushHooks.length) if (Reflect.compareMethods(LayoutTree.flushHooks[i],hook)) {LayoutTree.flushHooks.splice(i,1);break;}});
        }
        measure();
        poll();
		return root;
	}

	/**
	 * Reads the size of a character cell from the probe, as the code editor does.
	 * The probe is first laid out before its stylesheet font applies, so it is read
	 * again each frame until the size has held for a few.
	 */
	function measure():Void {
		var tries = 0, stable = 0, hook:LayoutTree->Void = null;
		hook = _ -> {
			var out = new hl.Bytes(36), info = new hl.Bytes(16);
			var n = probe.tree == null ? 0 : TextNative.blinc_text_carets(probe.tree.ptr, probe.node.id, ashui.core.Utf8.encode("M"), 0, 0, out, 3, info);
			if (n > 1) {
				var width = out.getF32((n - 1) * 12 + 4), height = info.getF32(0);
				if (Math.abs(width - cellWidth) > .01 || Math.abs(height - cellHeight) > .01) {
					cellWidth = width;
					cellHeight = height;
					stable = 0;
					measured.set(measured.get() + 1);
				} else
					stable++;
			}
			if (++tries > 120 || stable > 6)
				LayoutTree.flushHooks.remove(hook);
		};
		LayoutTree.flushHooks.push(hook);
		Owner.onCleanup(() -> {for (i in 0...LayoutTree.flushHooks.length) if (Reflect.compareMethods(LayoutTree.flushHooks[i],hook)) {LayoutTree.flushHooks.splice(i,1);break;}});
	}

	function rowElements(states:Array<RowState>):Array<Element>
		return [for (state in states) rowElement(state)];

	function rowElement(state:RowState):Element
		return <div position={Absolute} left={0} top={state.index * cellHeight} height={cellHeight} pointerEvents={PointerEvents.None}>
			<for {list in [state.items.get()]}>${runElements(list)}</for>
		</div>;

	function runElements(items:Array<Item>):Array<Element>
		return [for (item in items) runElement(item.run)];

	/** `text` with the characters the canvas draws itself, box lines and blocks, replaced by spaces. */
	static function withoutDrawn(text:String):String {
		var drawn = false;
		for (i in 0...text.length)
			if (BoxDrawing.draws(text.charCodeAt(i))) {
				drawn = true;
				break;
			}
		if (!drawn)
			return text;
		var out = new StringBuf();
		for (i in 0...text.length)
			out.add(BoxDrawing.draws(text.charCodeAt(i)) ? " " : text.charAt(i));
		return out.toString();
	}

	/** One run of text: placed by its column, in its colour, bold or italic. */
	function runElement(run:Run):Element {
		var theme = ThemeState.get(), fg = theme.color(TextPrimary).rgb();
		var front = resolve(run.fg, fg);
		if (run.attrs & 8 != 0)
			front = run.bg == 0 ? theme.color(Surface).rgb() : resolve(run.bg, fg);
		return <text position={Absolute} left={run.col * cellWidth} top={0} class="rayde-term-text" color={new Color(front)}
			fontWeight={run.attrs & 1 != 0 ? FontWeight.Bold : FontWeight.Normal} fontStyle={run.attrs & 2 != 0 ? FontStyle.Italic : FontStyle.Normal}
			pointerEvents={PointerEvents.None} wrap={false}>${withoutDrawn(run.text)}</text>;
	}

	/** Gives the terminal the keyboard. */
	public function focus():Void
		ashui.input.Focus.set(Interaction.of(root.node), true);

	// Keeping up with the terminal

	function poll():Void {
		if (gone)
			return;
		var now = haxe.Timer.stamp();
		if (props.shown()) {
			var pending = props.terminal.starting();
			launching.set(pending);
			if (pending) { later(.01); return; }
			var changed = false;
			var b = cellWidth == 0 ? null : root.tree.getBounds(root.node);
			if (b != null && b.width > 0) {
				wantCols = Std.int((b.width - 2 * PAD) / cellWidth);
				wantRows = Std.int((b.height - PAD) / cellHeight);
				if (props.terminal.remote) {wantCols = Std.int(Math.min(300,wantCols));wantRows = Std.int(Math.min(100,wantRows));}
			}
			if (wantCols > 1 && wantRows > 0 && (wantCols != screen.cols || wantRows != screen.rows)) {
				props.terminal.resize(wantCols, wantRows);
				// A remote resize is painted when its screen revision arrives.
				changed = !props.terminal.remote;
			}
			var r = props.terminal.revision();
			if (r != seen || changed) {
				seen = r;
				lastOutput = now;
				refresh();
				changed = true;
			}
			if (!exited) {
				var code = props.terminal.exitCode();
				if (code != -1 && code != -3) {
					exited = true;
					exitCode.set(code);
					changed = true;
					if (props.onExit != null)
						props.onExit(code);
				}
			}
			if (changed)
				revision.set(revision.get() + 1);
		}
		// The longer it has been quiet, the less often it is looked at; input brings the next look forward (see `soon`).
		var quiet = now - lastOutput;
		later(!props.shown() ? .5 : quiet < .6 ? .03 : quiet < 5 ? .1 : .4);
	}

	function later(delay:Float):Void {
		if (props.terminal.remote) return;
		if (pollTimer != null)
			pollTimer.cancel();
		pollTimer = AnimationScheduler.main.after(delay, poll);
	}

	/** Input is on its way to the program and its answer follows: look at the terminal again at once and keep looking closely for a while. */
	function soon():Void {
		lastOutput = haxe.Timer.stamp();
		later(.01);
	}

	/** Fetches the rows that changed, and the screen's state, and gives the changed rows their elements. */
	function refresh():Void {
		screen = props.terminal.screen();
		while (rows.length > screen.rows)
			rows.pop();
		while (rows.length < screen.rows)
			rows.push([]);
		if (rowStates.get().length != screen.rows)
			rowStates.set([for (i in 0...screen.rows) {index: i, items: Signal.make(([] : Array<Item>))}]);
		var states = rowStates.get();
		for (r in props.terminal.dirtyRows())
			if (r < rows.length) {
				rows[r] = props.terminal.row(r);
				states[r].items.set([for (run in rows[r]) {run: run}]);
			}
	}

	/** Makes every row's elements again from the rows as fetched. */
	function repaintRows():Void {
		for (state in rowStates.get())
			if (state.index < rows.length)
				state.items.set([for (run in rows[state.index]) {run: run}]);
	}

	// Drawing

	function resolve(code:Int, fallback:Int):Int
		return rayde.run.AnsiColors.resolve(code, fallback, ThemeState.get().scheme() == Dark);

	/** What is under the text: each run's background, underlines, the selection and the cursor. */
	function paint(ctx:DrawContext):Void {
		var theme = ThemeState.get();
		theme.revision.get();
		revision.get();
		measured.get();
		if (props.changes != null)
			props.changes.get();
		if (cellWidth == 0)
			return;
		var fg = theme.color(TextPrimary).rgb();
		if (selection() != null)
			highlight(ctx, theme.color(Primary).rgb());
		for (r => runs in rows) {
			var y = PAD / 2 + r * cellHeight;
			for (run in runs) {
				var inverse = run.attrs & 8 != 0, back = resolve(run.bg, -1), front = resolve(run.fg, fg);
				if (inverse)
					back = run.fg == 0 ? fg : front;
				var x = PAD + run.col * cellWidth;
				if (back != -1)
					ctx.fillRect(x, y, run.cells * cellWidth, cellHeight, Brush.solid(back));
				if (run.attrs & 4 != 0)
					ctx.fillRect(x, y + cellHeight - 2, run.cells * cellWidth, 1, Brush.solid(inverse ? back : front));
				for (i in 0...run.text.length) {
					var code = run.text.charCodeAt(i);
					if (BoxDrawing.draws(code))
						BoxDrawing.draw(ctx, code, x + i * cellWidth, y, cellWidth, cellHeight, inverse ? resolve(run.bg, theme.color(Surface).rgb()) : front);
				}
			}
		}
		if (screen.cursorShown && screen.scrollback == 0 && !exited) {
			var x = PAD + screen.cursorColumn * cellWidth, y = PAD / 2 + screen.cursorRow * cellHeight;
			// While the terminal has the keyboard the cursor is solid, as the settings shape it, and it does not blink; without, an outline.
			var style = props.settings == null ? "block" : props.settings.cursor;
			if (focused) {
				var solid = Brush.solid(fg, style == "block" ? .45 : .9);
				switch style {
					case "bar": ctx.fillRect(x, y, 2, cellHeight, solid);
					case "underline": ctx.fillRect(x, y + cellHeight - 2, cellWidth, 2, solid);
					case _: ctx.fillRect(x, y, cellWidth, cellHeight, solid);
				}
			} else {
				var line = Brush.solid(fg, .6);
				ctx.fillRect(x, y, cellWidth, 1, line);
				ctx.fillRect(x, y + cellHeight - 1, cellWidth, 1, line);
				ctx.fillRect(x, y, 1, cellHeight, line);
				ctx.fillRect(x + cellWidth - 1, y, 1, cellHeight, line);
			}
		}
	}

	/** Paints what the pointer has selected. */
	function highlight(ctx:DrawContext, color:Int):Void {
		var s = selection();
		for (r in s.r1...s.r2 + 1) {
			var from = r == s.r1 ? s.c1 : 0, to = r == s.r2 ? s.c2 : screen.cols;
			ctx.fillRect(PAD + from * cellWidth, PAD / 2 + r * cellHeight, (to - from) * cellWidth, cellHeight, Brush.solid(color, .35));
		}
	}

	/** The selection, from its first cell to just after its last, in reading order; null when there is none. */
	function selection():Null<{r1:Int, c1:Int, r2:Int, c2:Int}> {
		if (anchor == null || head == null || anchor.row == head.row && anchor.col == head.col)
			return null;
		var first = anchor.row < head.row || anchor.row == head.row && anchor.col < head.col;
		var a = first ? anchor : head, b = first ? head : anchor;
		return {r1: a.row, c1: a.col, r2: b.row, c2: b.col + 1};
	}

	// Keys

	function key(e:KeyEvent):Void {
		var command = e.superKey;
		switch e.key {
			case Character("c") | Character("C") if (command || e.control && e.shift):
				var text = selectedText();
				if (text != "") {
					Clipboard.setText(text);
					e.preventDefault();
				}
				return;
			case Character("v") | Character("V") if (command || e.control && e.shift):
				paste(Clipboard.text());
				e.preventDefault();
				return;
			case _:
		}
		// The workbench's own shortcuts, and the keys that would move focus out, are not the program's.
		if (command || e.control && e.key.match(Character("`")) || props.reserved != null && props.reserved(e))
			return;
		var text = KeyMap.encode(e.key, e.shift, e.control, e.alt, screen.applicationCursor);
		if (text == null)
			return;
		if (screen.scrollback > 0)
			props.terminal.scrollback(0);
		anchor = head = null;
		props.terminal.write(text);
		soon();
		e.preventDefault();
	}

	function paste(text:String):Void {
		if (text == null || text == "")
			return;
		var body = ~/\r?\n/g.replace(text, "\r");
		props.terminal.write(screen.bracketedPaste ? "\x1b[200~" + body + "\x1b[201~" : body);
		soon();
	}

	function selectedText():String {
		var s = selection();
		return s == null ? "" : props.terminal.text(s.r1, s.c1, s.r2, s.c2);
	}

	// Pointer

	/** The cell under the point `(x, y)` of the tree. */
	function cell(x:Float, y:Float):{row:Int, col:Int} {
		var b = root.tree.getBounds(root.node);
		if (b == null || cellWidth == 0)
			return {row: 0, col: 0};
		return {
			row: Std.int(Math.max(0, Math.min(screen.rows - 1, Math.floor((y - b.y - PAD / 2) / cellHeight)))),
			col: Std.int(Math.max(0, Math.min(screen.cols - 1, Math.floor((x - b.x - PAD) / cellWidth))))
		};
	}

	function down(e:PointerEvent):Void {
		focus();
		var at = cell(e.x, e.y);
		if (screen.mouseMode > 0) {
			var report = KeyMap.mouse(0, at.col + 1, at.row + 1, false, screen.mouseEncoding);
			if (report != null)
				props.terminal.write(report);
			soon();
			trackRelease(at);
			return;
		}
		stopDrag();
		anchor = head = at;
		revision.set(revision.get() + 1);
		var tree = root.tree;
		drag = t -> if (t == tree) {
			var p = Pointer.at(tree);
			if (p.pressed) {
				head = cell(p.x, p.y);
				revision.set(revision.get() + 1);
			} else {
				stopDrag();
				if (props.settings != null && props.settings.copyOnSelect) {
					var text = selectedText();
					if (text != "")
						Clipboard.setText(text);
				}
			}
		};
		Pointer.hooks.push(drag);
	}

	/** Tells a program that asked for the mouse when the button comes up. */
	function trackRelease(at:{row:Int, col:Int}):Void {
		stopDrag();
		var tree = root.tree;
		drag = t -> if (t == tree && !Pointer.at(tree).pressed) {
			var report = KeyMap.mouse(0, at.col + 1, at.row + 1, true, screen.mouseEncoding);
			if (report != null)
				props.terminal.write(report);
			stopDrag();
		};
		Pointer.hooks.push(drag);
	}

	function stopDrag():Void {
		if (drag != null)
			Pointer.hooks.remove(drag);
		drag = null;
	}

	function wheel(e:PointerEvent):Void {
		if (e.deltaY == 0 || cellHeight == 0)
			return;
		var lines = Std.int(Math.max(1, Math.round(Math.abs(e.deltaY) / cellHeight)));
		if (screen.mouseMode > 0) {
			var at = cell(e.x, e.y), report = KeyMap.mouse(e.deltaY < 0 ? 64 : 65, at.col + 1, at.row + 1, false, screen.mouseEncoding);
			if (report != null)
				for (_ in 0...lines)
					props.terminal.write(report);
			soon();
			return;
		}
		// Up shows older output, down newer.
		props.terminal.scrollback(Std.int(Math.max(0, screen.scrollback + (e.deltaY < 0 ? lines : -lines))));
		seen = -1;
		soon();
	}
}
