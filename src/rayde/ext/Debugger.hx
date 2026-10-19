package rayde.ext;

import ashui.reactive.Signal;

/** A line of a file that stops the extension. */
typedef Breakpoint = {file:String, line:Int};

/** A call in the stack of a stopped extension. */
typedef StackFrame = {name:String, file:String, line:Int, col:Int};

/** A variable or a member of one: `ref` is not 0 when there is more inside. */
typedef Variable = {name:String, value:String, type:String, ref:Int};

/** Where the extension stopped, and why: breakpoint, step or pause. */
typedef Stop = {reason:String, frames:Array<StackFrame>};

/** What an expression evaluated to in the selected frame, or why it did not. */
typedef Evaluation = {expr:String, ok:Bool, text:String, type:String, ref:Int};

/**
 * The debugging of one extension as the editor sees it: the breakpoints, which it keeps and tells the host, and,
 * while the extension is stopped, its stack and the variables of the frame chosen. What the host says arrives
 * through `handle`; what the editor asks goes out through the function `connect` was given. The extension
 * runs nothing while it is stopped, and holds the events that come.
 */
class Debugger {
	public final breakpoints = Signal.make(([] : Array<Breakpoint>));

	/** Null while the extension is running. */
	public final stopped = Signal.make((null : Null<Stop>));

	/** The frame whose variables are shown; 0 is the innermost. */
	public final frame = Signal.make(0);

	public final locals = Signal.make(([] : Array<Variable>));
	public final globals = Signal.make(([] : Array<Variable>));

	/** Changes when a variable has been opened or closed, or its members have come. */
	public final opened = Signal.make(0);

	public final evaluation = Signal.make((null : Null<Evaluation>));

	/** Called when the extension stops. */
	public var onStop:Null<Stop->Void>;

	/** Called when the breakpoints change, to be kept. */
	public var onChange:Null<Void->Void>;

	final members = new Map<Int, Array<Variable>>();
	final open = new Map<Int, Bool>();
	var send:Null<Dynamic->Bool>;

	public function new() {}

	/** The host has started: gives it the breakpoints before it runs anything. */
	public function connect(send:Dynamic->Bool):Void {
		this.send = send;
		for (file in files())
			tell(file);
	}

	/** The host has gone: nothing is stopped. */
	public function disconnect():Void {
		send = null;
		forget();
		stopped.set(null);
	}

	function files():Array<String> {
		var out = [];
		for (b in breakpoints.get())
			if (out.indexOf(b.file) < 0)
				out.push(b.file);
		return out;
	}

	public function linesOf(file:String):Array<Int>
		return [for (b in breakpoints.get()) if (b.file == file) b.line];

	function tell(file:String):Void {
		if (send != null)
			send({t: "debug", op: "breakpoints", file: file, lines: linesOf(file)});
	}

	/** Puts breakpoints on `list`, as kept earlier. */
	public function load(list:Array<Breakpoint>):Void {
		breakpoints.set(list.copy());
		for (file in files())
			tell(file);
	}

	/** Puts a breakpoint on the line, or takes the one there away; whether there is one now. */
	public function toggle(file:String, line:Int):Bool {
		var had = Lambda.exists(breakpoints.get(), b -> b.file == file && b.line == line);
		var rest = [for (b in breakpoints.get()) if (!(b.file == file && b.line == line)) b];
		if (!had)
			rest.push({file: file, line: line});
		rest.sort((a, b) -> a.file == b.file ? a.line - b.line : Reflect.compare(a.file, b.file));
		breakpoints.set(rest);
		tell(file);
		changed();
		return !had;
	}

	/** Puts the breakpoints of a file on `lines`, as the editor moved them with the text; the host is told. */
	public function setLines(file:String, lines:Array<Int>):Void {
		var sorted = lines.copy();
		sorted.sort((a, b) -> a - b);
		if (linesOf(file).join(",") == sorted.join(","))
			return;
		var rest = [for (b in breakpoints.get()) if (b.file != file) b];
		for (l in sorted)
			rest.push({file: file, line: l});
		rest.sort((a, b) -> a.file == b.file ? a.line - b.line : Reflect.compare(a.file, b.file));
		breakpoints.set(rest);
		tell(file);
		changed();
	}

	public function remove(file:String, line:Int):Void
		if (Lambda.exists(breakpoints.get(), b -> b.file == file && b.line == line))
			toggle(file, line);

	public function clear():Void {
		var before = files();
		breakpoints.set([]);
		for (file in before)
			tell(file);
		changed();
	}

	function changed():Void
		if (onChange != null)
			onChange();

	/** Asks the running extension to stop at its next instruction. */
	public function pause():Void
		if (send != null)
			send({t: "debug", op: "pause"});

	/** Lets the stopped extension go on: `continue`, `stepOver`, `stepIn` or `stepOut`. */
	public function resume(how:String):Void
		if (send != null && stopped.get() != null)
			send({t: "debug", op: how});

	/** Shows the variables of a frame of the stack. */
	public function select(index:Int):Void {
		frame.set(index);
		forget();
		if (send != null)
			send({t: "debug", op: "variables", frame: index});
	}

	/** Opens or closes a variable that has members, asking the host for them the first time. */
	public function toggleOpen(ref:Int):Void {
		if (ref == 0)
			return;
		if (open.exists(ref)) {
			open.remove(ref);
		} else {
			open.set(ref, true);
			if (!members.exists(ref) && send != null)
				send({t: "debug", op: "expand", ref: ref});
		}
		opened.set(opened.get() + 1);
	}

	public function isOpen(ref:Int):Bool
		return open.exists(ref);

	/** The members of an open variable, once they have come. */
	public function membersOf(ref:Int):Array<Variable> {
		var m = members.get(ref);
		return m == null ? [] : m;
	}

	/** Evaluates a path of names and members in the selected frame. */
	public function evaluate(expr:String):Void
		if (send != null && stopped.get() != null && StringTools.trim(expr) != "")
			send({t: "debug", op: "evaluate", frame: frame.get(), expr: expr});

	function forget():Void {
		members.clear();
		open.clear();
		opened.set(opened.get() + 1);
	}

	static function variables(list:Array<Dynamic>):Array<Variable>
		return [for (v in list) {name: Std.string(v.name), value: Std.string(v.value), type: Std.string(v.type), ref: Std.int(v.ref)}];

	/** Takes what the host said; whether it was about debugging. */
	public function handle(m:Dynamic):Bool {
		switch (m.t : String) {
			case "paused":
				var frames:Array<StackFrame> = [
					for (f in (m.frames : Array<Dynamic>))
						{name: Std.string(Reflect.field(f, "function")), file: Std.string(f.file), line: Std.int(f.line), col: Std.int(f.col)}
				];
				var stop = {reason: Std.string(m.reason), frames: frames};
				stopped.set(stop);
				evaluation.set(null);
				locals.set([]);
				globals.set([]);
				select(0);
				if (onStop != null)
					onStop(stop);
			case "resumed":
				stopped.set(null);
				locals.set([]);
				globals.set([]);
				evaluation.set(null);
				forget();
			case "variables":
				if (Std.int(m.frame) == frame.get()) {
					locals.set(variables(m.locals));
					globals.set(variables(m.globals));
				}
			case "children":
				members.set(Std.int(m.ref), variables(m.items));
				opened.set(opened.get() + 1);
			case "evaluated":
				if (m.ok == true) {
					var r = m.result;
					evaluation.set({expr: Std.string(m.expr), ok: true, text: Std.string(r.value), type: Std.string(r.type), ref: Std.int(r.ref)});
				} else
					evaluation.set({expr: Std.string(m.expr), ok: false, text: Std.string(m.message), type: "", ref: 0});
			case "breakpoints":
				// The lines as the host has them, each moved to a line that has code.
				var file = Std.string(m.file), lines:Array<Int> = [for (l in (m.lines : Array<Dynamic>)) Std.int(l)];
				var mine = linesOf(file);
				if (mine.join(",") != lines.join(",")) {
					var rest = [for (b in breakpoints.get()) if (b.file != file) b];
					for (l in lines)
						if (!Lambda.exists(rest, b -> b.file == file && b.line == l))
							rest.push({file: file, line: l});
					rest.sort((a, b) -> a.file == b.file ? a.line - b.line : Reflect.compare(a.file, b.file));
					breakpoints.set(rest);
					changed();
				}
			case _:
				return false;
		}
		return true;
	}
}
