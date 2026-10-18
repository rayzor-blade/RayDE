package rayde.ui;

import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Tabs;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.ext.Studio;
import rayde.ext.Debugger.Evaluation;
import rayde.ext.Debugger.Stop;
import rayde.ext.Debugger.Variable;
import rayde.ext.Studio.Entry;

typedef StudioPanelsProps = {
	/** The extension of the file in front, if it is one. */
	studio:Signal<Null<Studio>>,
	onOpen:(file:String, line:Int, col:Int) -> Void
};

/**
 * What the extension in front has said and done: its Console (what it traced, and where it failed), its
 * Activity (the events, remote calls and operations that crossed to and from it) and its Elements.
 */
class StudioPanels extends Component<StudioPanelsProps> {
	/** The most rows a list draws: the newest. */
	static inline var ROWS = 300;

	/** The extension in front and the part of its panel that is open. */
	function panelState():{studio:Null<Studio>, which:String} {
		var s = props.studio.get();
		return {studio: s, which: s == null ? "console" : s.panel.get()};
	}

	final evaluateText = Signal.make("");

	function render():Element
		return <div id="rayde-extension" class="flex flex-col flex-1 min-h-0">
			<for {state in [panelState()]}>${body(state.studio, state.which)}</for>
		</div>;

	function body(studio:Null<Studio>, which:String):Element {
		if (studio == null)
			return <div class="flex flex-col gap-1 px-2 py-1">
				<text id="rayde-extension-empty" class="text-xs text-text-secondary">No active extension.</text>
				<text class="text-xs text-text-tertiary">Open a .rays file or a .rayext project to run an extension.</text>
			</div>;
		return <div class="flex flex-1 min-h-0">
			<div class="flex flex-col gap-1 shrink-0 pr-2" width={116}>
				${pick(studio, "console", "Console", Icons.TERMINAL_BOX_LINE, which)}
				${pick(studio, "activity", "Activity", Icons.BROADCAST_LINE, which)}
				${pick(studio, "elements", "Elements", Icons.NODE_TREE, which)}
				${pick(studio, "debug", "Debug", Icons.BUG_LINE, which)}
			</div>
			<div class="flex flex-col flex-1 min-w-0 min-h-0">${pane(studio, which)}</div>
		</div>;
	}

	function pick(studio:Studio, id:String, label:String, icon:ashui.svg.SvgDocument, current:String):Element {
		var item = <div id={"rayde-extension-" + id} class="rayde-extension-pick flex items-center gap-2 px-2 cursor-pointer" height={28} onClick={_ -> studio.panel.set(id)}>
			<icon document={icon} class="size-4 shrink-0"/>
			<text class="text-xs">${label}</text>
		</div>;
		if (id == current)
			ashui.css.Identity.of(item.tree, item.node.id).setAttribute("data-on", "");
		return item;
	}

	function pane(studio:Studio, which:String):Element
		return switch which {
			case "activity": <for {list in [studio.activity.get()]}>${entries(list, "No activity.", false)}</for>;
			case "elements": <for {n in [studio.elements.get()]}>${outline(studio)}</for>;
			case "debug": <for {n in [studio.running()]}>${debugPane(studio)}</for>;
			case _: <for {list in [studio.console.get()]}>${entries(list, "No console output.", true)}</for>;
		}

	function entries(list:Array<Entry>, none:String, jump:Bool):Element {
		var shown = list.length > ROWS ? list.slice(list.length - ROWS) : list;
		return <div class="flex flex-col flex-1 min-h-0 overflow-auto">
			<if {shown.length == 0}><div class="px-2 py-1"><text class="text-xs text-text-tertiary">${none}</text></div></if>
			{[for (e in shown) entry(e, jump)]}
		</div>;
	}

	function entry(e:Entry, jump:Bool):Element {
		var place = jump && e.file != null && e.line != null;
		var row = <div class="rayde-entry flex items-start gap-2 px-2 py-1" onClick={_ -> if (place) props.onOpen(e.file, e.line - 1, e.col == null ? 0 : e.col - 1)}>
			<if {e.kind == "error"}><icon document={Icons.CLOSE_CIRCLE_LINE} class="size-4 shrink-0 text-error"/>
			<else><if {e.kind == "info"}><icon document={Icons.INFORMATION_LINE} class="size-4 shrink-0 text-text-tertiary"/>
			<else><div class="size-4 shrink-0"/></if></if>
			${message(e)}
			<if {place}><text class="text-xs text-text-tertiary shrink-0">${haxe.io.Path.withoutDirectory(e.file) + ":" + e.line}</text></if>
		</div>;
		if (place)
			ashui.css.Identity.of(row.tree, row.node.id).setAttribute("data-jump", "");
		return row;
	}

	/** The text of an entry, in the colour its kind has. */
	function message(e:Entry):Element
		return switch e.kind {
			case "error": <text class="text-xs flex-1 min-w-0 text-error">${e.text}</text>;
			case "event" | "call" | "answer": <text class="text-xs flex-1 min-w-0 text-text-secondary">${e.text}</text>;
			case "ops": <text class="text-xs flex-1 min-w-0 text-text-tertiary">${e.text}</text>;
			case _: <text class="text-xs flex-1 min-w-0 text-text-primary">${e.text}</text>;
		}

	function outline(studio:Studio):Element {
		var rows = studio.preview == null ? [] : studio.preview.outline();
		return <div id="rayde-elements" class="flex flex-col flex-1 min-h-0 overflow-auto">
			<if {rows.length == 0}><div class="px-2 py-1"><text class="text-xs text-text-tertiary">No view mounted.</text></div></if>
			{[for (r in rows) <div class="rayde-element flex items-center gap-2 py-0.5" paddingLeft={8 + r.depth * 14}>
				<if {r.tag == null}><text class="text-xs text-text-tertiary">${"\"" + r.text + "\""}</text>
				<else><text class="text-xs text-primary">${"<" + r.tag + ">"}</text></if>
				<text class="text-xs text-text-tertiary min-w-0">${r.props.join(" ") + (r.listens.length > 0 ? "  on: " + r.listens.join(", ") : "")}</text>
			</div>]}
		</div>;
	}

	// Debug

	function debugPane(studio:Studio):Element
		return <div id="rayde-debug" class="flex flex-col flex-1 min-h-0 min-w-0">
			<for {key in [debugKey(studio)]}>${debugBody(studio)}</for>
		</div>;

	/** A new value whenever the stop or the chosen frame changes, so the Debug pane is drawn again. */
	function debugKey(studio:Studio):{} {
		studio.debug.stopped.get();
		studio.debug.frame.get();
		return {};
	}

	function debugBody(studio:Studio):Element {
		var d = studio.debug, stop = d.stopped.get(), selected = d.frame.get(), stopped = stop != null;
		var where = stopped ? stop.frames[0] : null;
		return <div class="flex flex-col flex-1 min-h-0 min-w-0">
			<div class="flex items-center gap-1 px-2 shrink-0" height={32}>
				${stopped ? control("rayde-debug-continue", "Continue (F5)", Icons.PLAY_FILL, () -> d.resume("continue"), true) : control("rayde-debug-pause", "Pause (F6)", Icons.PAUSE_FILL, () -> d.pause(), studio.running())}
				${control("rayde-debug-over", "Step Over (F10)", Icons.ARROW_GO_FORWARD_LINE, () -> d.resume("stepOver"), stopped)}
				${control("rayde-debug-into", "Step Into (F11)", Icons.CORNER_RIGHT_DOWN_LINE, () -> d.resume("stepIn"), stopped)}
				${control("rayde-debug-out", "Step Out (Shift+F11)", Icons.CORNER_UP_RIGHT_LINE, () -> d.resume("stepOut"), stopped)}
				<text id="rayde-debug-status" class="text-xs text-text-secondary flex-1 min-w-0 truncate pl-2">${stopped ? "Stopped (" + stop.reason + ") in " + where.name + " at " + haxe.io.Path.withoutDirectory(where.file) + ":" + where.line : studio.running() ? "Running" : "Not running"}</text>
			</div>
			<div class="flex flex-1 min-h-0 min-w-0 gap-2 px-2 pb-2">
				<div class="flex flex-col flex-1 min-w-0 min-h-0">${section("Call stack", stackRows(studio, stop, selected))}</div>
				<div class="flex flex-col flex-1 min-w-0 min-h-0">${section("Variables", variableRows(studio, stopped))}</div>
				<div class="flex flex-col flex-1 min-w-0 min-h-0">${section("Breakpoints", breakpointRows(studio))}</div>
			</div>
		</div>;
	}

	function control(id:String, label:String, icon:ashui.svg.SvgDocument, run:Void->Void, enabled:Bool):Element
		return <tooltip label={label} side="bottom"><button id={id} variant={Ghost} size={Icon} class="rayde-panel-button" disabled={!enabled} onClick={_ -> run()}><icon document={icon} class="size-4"/></button></tooltip>;

	function section(title:String, rows:Array<Element>):Element
		return <div class="flex flex-col flex-1 min-h-0">
			<text class="text-xs font-semibold text-text-secondary px-1 pb-1 shrink-0">${title}</text>
			<div class="flex flex-col flex-1 min-h-0 overflow-auto">{rows}</div>
		</div>;

	function stackRows(studio:Studio, stop:Null<Stop>, selected:Int):Array<Element> {
		if (stop == null)
			return [<div class="px-1"><text class="text-xs text-text-tertiary">Not stopped.</text></div>];
		return [
			for (i => f in stop.frames) {
				var row = <div id={"rayde-frame-" + i} class="rayde-entry flex items-center gap-2 px-2 py-1" onClick={_ -> {
					studio.debug.select(i);
					props.onOpen(f.file, f.line - 1, f.col - 1);
				}}>
					<text class="text-xs text-text-primary shrink-0">${f.name}</text>
					<text class="text-xs text-text-tertiary flex-1 min-w-0 truncate">${haxe.io.Path.withoutDirectory(f.file) + ":" + f.line}</text>
				</div>;
				var identity = ashui.css.Identity.of(row.tree, row.node.id);
				identity.setAttribute("data-jump", "");
				if (i == selected)
					identity.setAttribute("data-on", "");
				row;
			}
		];
	}

	function variableRows(studio:Studio, stopped:Bool):Array<Element> {
		if (!stopped)
			return [<div class="px-1"><text class="text-xs text-text-tertiary">Variables are shown while stopped.</text></div>];
		var d = studio.debug, out:Array<Element> = [];
		out.push(<div class="flex items-center gap-2 px-1 pb-1 shrink-0">
			<input height={28} id="rayde-debug-evaluate" value={evaluateText} placeholder="Evaluate a name or a path, such as items[0].title" class="rayde-control-wide" onKeyDown={e -> if (e.key.match(Named(Enter))) d.evaluate(evaluateText.get())}/>
		</div>);
		out.push(<for {k in [evaluationKey(d)]}>${evaluationRow(d.evaluation.get())}</for>);
		out.push(<for {k in [variableKey(d)]}>${variableTree(d)}</for>);
		return out;
	}

	function evaluationKey(d:rayde.ext.Debugger):{} {
		d.evaluation.get();
		return {};
	}

	/** A new value each time the variables, or whether each is open, change. */
	function variableKey(d:rayde.ext.Debugger):{} {
		d.opened.get();
		d.locals.get();
		d.globals.get();
		return {};
	}

	function evaluationRow(e:Null<Evaluation>):Element {
		if (e == null)
			return <div/>;
		return <div id="rayde-debug-result" class="flex items-center gap-2 px-2 py-1 shrink-0">
			<text class="rayde-mono text-xs text-text-tertiary shrink-0">${e.expr}</text>
			{e.ok ? <text class="rayde-mono text-xs text-text-primary flex-1 min-w-0 truncate">${e.text}</text> : <text class="text-xs text-error flex-1 min-w-0 truncate">${e.text}</text>}
		</div>;
	}

	function variableTree(d:rayde.ext.Debugger):Element {
		var locals = d.locals.get(), globals = d.globals.get(), rows:Array<Element> = [];
		function add(list:Array<Variable>, depth:Int):Void
			for (v in list) {
				rows.push(variableRow(d, v, depth));
				if (v.ref != 0 && d.isOpen(v.ref))
					add(d.membersOf(v.ref), depth + 1);
			}
		if (locals.length > 0) {
			rows.push(<text class="text-xs text-text-tertiary px-1 pt-1">Locals</text>);
			add(locals, 0);
		}
		rows.push(<text class="text-xs text-text-tertiary px-1 pt-1">Module</text>);
		add(globals, 0);
		return <div class="flex flex-col">{rows}</div>;
	}

	function variableRow(d:rayde.ext.Debugger, v:Variable, depth:Int):Element
		return <div class="rayde-entry flex items-center gap-1 py-0.5 pr-2" paddingLeft={4 + depth * 14} onClick={_ -> d.toggleOpen(v.ref)}>
			{v.ref == 0 ? <div class="size-4 shrink-0"/> : <icon document={d.isOpen(v.ref) ? Icons.ARROW_DOWN_S_LINE : Icons.ARROW_RIGHT_S_LINE} class="size-4 shrink-0 text-text-tertiary"/>}
			<text class="rayde-mono text-xs text-primary shrink-0">${v.name}</text>
			<text class="rayde-mono text-xs text-text-primary flex-1 min-w-0 truncate">${v.value}</text>
			<text class="text-xs text-text-tertiary shrink-0">${v.type}</text>
		</div>;

	function breakpointRows(studio:Studio):Array<Element> {
		var d = studio.debug;
		return [<for {k in [breakpointKey(d)]}>${breakpointList(d, d.breakpoints.get())}</for>];
	}

	function breakpointKey(d:rayde.ext.Debugger):{} {
		d.breakpoints.get();
		return {};
	}

	function breakpointList(d:rayde.ext.Debugger, list:Array<rayde.ext.Debugger.Breakpoint>):Element
		return <div class="flex flex-col">
			<if {list.length == 0}><div class="px-1"><text id="rayde-debug-no-breakpoints" class="text-xs text-text-tertiary">None. Toggle Breakpoint (F9) puts one on the line the cursor is on.</text></div></if>
			{[for (b in list) breakpointRow(d, b)]}
		</div>;

	function breakpointRow(d:rayde.ext.Debugger, b:rayde.ext.Debugger.Breakpoint):Element {
		var row = <div class="rayde-entry flex items-center gap-2 px-2 py-1" onClick={_ -> props.onOpen(b.file, b.line - 1, 0)}>
			<icon document={Icons.CIRCLE_FILL} class="size-3 shrink-0 text-error"/>
			<text class="text-xs text-text-primary flex-1 min-w-0 truncate">${haxe.io.Path.withoutDirectory(b.file) + ":" + b.line}</text>
			<tooltip label="Remove"><button variant={Ghost} size={Icon} class="rayde-remove" onClick={e -> {
				e.stopPropagation();
				d.remove(b.file, b.line);
			}}><icon document={Icons.CLOSE_LINE} class="size-4"/></button></tooltip>
		</div>;
		ashui.css.Identity.of(row.tree, row.node.id).setAttribute("data-jump", "");
		return row;
	}
}
