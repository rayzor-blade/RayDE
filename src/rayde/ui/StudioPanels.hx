package rayde.ui;

import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Tabs;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.ext.Studio;
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

	final section = Signal.make("console");

	function render():Element
		return <div id="rayde-extension" class="flex flex-col flex-1 min-h-0">
			<for {state in [{studio: props.studio.get(), which: section.get()}]}>${body(state.studio, state.which)}</for>
		</div>;

	function body(studio:Null<Studio>, which:String):Element {
		if (studio == null)
			return <div class="flex flex-col gap-1 px-2 py-1">
				<text id="rayde-extension-empty" class="text-xs text-text-secondary">No extension in front.</text>
				<text class="text-xs text-text-tertiary">Open a .rays file to run it here and see its view beside the code.</text>
			</div>;
		return <div class="flex flex-1 min-h-0">
			<div class="flex flex-col gap-1 shrink-0 pr-2" width={116}>
				${pick("console", "Console", Icons.TERMINAL_BOX_LINE, which)}
				${pick("activity", "Activity", Icons.BROADCAST_LINE, which)}
				${pick("elements", "Elements", Icons.NODE_TREE, which)}
			</div>
			<div class="flex flex-col flex-1 min-w-0 min-h-0">${pane(studio, which)}</div>
		</div>;
	}

	function pick(id:String, label:String, icon:ashui.svg.SvgDocument, current:String):Element {
		var item = <div id={"rayde-extension-" + id} class="rayde-extension-pick flex items-center gap-2 px-2 cursor-pointer" height={28} onClick={_ -> section.set(id)}>
			<icon document={icon} class="size-4 shrink-0"/>
			<text class="text-xs">${label}</text>
		</div>;
		if (id == current)
			ashui.css.Identity.of(item.tree, item.node.id).setAttribute("data-on", "");
		return item;
	}

	function pane(studio:Studio, which:String):Element
		return switch which {
			case "activity": <for {list in [studio.activity.get()]}>${entries(list, "Nothing has happened yet.", false)}</for>;
			case "elements": <for {n in [studio.elements.get()]}>${outline(studio)}</for>;
			case _: <for {list in [studio.console.get()]}>${entries(list, "The extension has said nothing.", true)}</for>;
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
			<if {rows.length == 0}><div class="px-2 py-1"><text class="text-xs text-text-tertiary">The extension has not made a view yet.</text></div></if>
			{[for (r in rows) <div class="rayde-element flex items-center gap-2 py-0.5" paddingLeft={8 + r.depth * 14}>
				<if {r.tag == null}><text class="text-xs text-text-tertiary">${"\"" + r.text + "\""}</text>
				<else><text class="text-xs text-primary">${"<" + r.tag + ">"}</text></if>
				<text class="text-xs text-text-tertiary min-w-0">${r.props.join(" ") + (r.listens.length > 0 ? "  on: " + r.listens.join(", ") : "")}</text>
			</div>]}
		</div>;
	}
}
