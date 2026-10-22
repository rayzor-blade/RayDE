package rayde.ui;

import ashui.components.Floating;
import ashui.components.Icon;
import ashui.css.Css;
import ashui.input.Interaction;
import ashui.input.Pointer;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.reactive.Computed;
import ashui.css.Identity;
import ashui.reactive.Signal;
import ashui.reactive.Watch;
import ashui.types.Style;
import ashui.ui.Component;
import ashui.ui.Ref;

/** A command the center lists after `>`: what it says, how it looks, the keys that do it too, and what it does. */
typedef CenterAction = {
	id:String,
	label:String,
	icon:ashui.svg.SvgDocument,
	?shortcut:String,
	run:Void->Void
};

/** A list of choices to put in the center in place of its files and commands, with what to say in the filter. */
typedef Picker = {placeholder:String, items:Array<CenterAction>};

/** What the center opens with: the text in its filter, a serial so asking again starts it afresh, and a list of choices to show instead when it is to pick one. */
typedef CenterRequest = {text:String, serial:Int, ?picker:Picker};

typedef CommandCenterProps = {
	opened:Signal<Bool>,
	request:Signal<CenterRequest>,
	/** The element it hangs from: the project pill in the title bar. */
	anchor:Element,
	/** A reactive snapshot of project files, most recently opened first. */
	files:Void->Array<String>,
	?refreshFiles:Void->Void,
	/** The folder the listed paths are shown relative to. */
	root:String,
	actions:Array<CenterAction>,
	/** The project's tasks, which the center lists after `task `; asked for each time it opens. */
	tasks:Void->Array<CenterAction>,
	onOpenFile:String->Void,
	onLine:Int->Void
};

private typedef Choice = {id:String, value:String, label:String, detail:String, icon:ashui.svg.SvgDocument, shortcut:String, search:String};

/**
 * The command center, as VS Code's: a panel under the title bar's project
 * pill, over the page and not instead of it, that goes to a file as typed, to a
 * command after `>`, and to a line after `:`. The page stays live under it; a
 * press outside, or Escape, closes it. Catalogs contain data; only the visible
 * result rows are mounted, with keyboard navigation across the full catalog.
 */
class CommandCenter extends Component<CommandCenterProps> {
	final input = new Ref<ashui.ui.Input>();
	final mode = Signal.make("files");
	final builds = Signal.make(0);
	final mounted = Signal.make(false);

	/** What the filter holds when the list is next made: what it was opened with, or what was typed across a change of mode. */
	var carry = "";

	var panel:Element;
	var floating:Floating;

	/** The list of choices the center was opened to pick from, or null when it goes to files and commands. */
	var picker:Null<Picker> = null;
	var choices:Array<CenterAction> = [];

	function render():Element {
		panel = <div id="rayde-command-center" class="rayde-glass rayde-command-center flex flex-col overflow-hidden" width={600}>
			<if {mounted.get()}><for {k in [{mode: mode.get(), build: builds.get()}]}>${body(k.mode)}</for></if>
		</div>;
		var root = <div position={Absolute} width={0} height={0}/>;
		floating = new Floating(props.opened, panel);
		floating.modeless = true;
		floating.opened = () -> if (input.get() != null) input.get().focus();
		floating.anchorTo(props.anchor, "bottom", 8);
		new Watch(() -> {
			props.opened.get();
			props.request.get();
			0;
		}, _ -> if (props.opened.get()) {
			carry = props.request.get().text;
			picker = props.request.get().picker;
			mode.set(picker != null ? "pick" : modeOf(carry));
			builds.set(builds.get() + 1);
			mounted.set(true);
		} else {
			mounted.set(false);
			picker = null;
			choices = [];
			carry = "";
		}, (_, _) -> false);
		// A press outside the panel and its pill closes it; the pill closes it itself when it is open.
		var outside:LayoutTree->Void = tree -> if (tree == root.tree
			&& props.opened.get()
			&& Pointer.at(tree).pressed
			&& !Interaction.of(panel.node).hovered.get()
			&& !Interaction.of(props.anchor.node).hovered.get())
			props.opened.set(false);
		// Only while it is open: a hook makes every pointer move in the window work, where none lets a still region sleep.
		var hooked = false;
		new Watch(() -> props.opened.get(), open -> {
			if (open && !hooked)
				Pointer.hooks.push(outside);
			else if (!open && hooked)
				Pointer.hooks.remove(outside);
			hooked = open;
		});
		Owner.onCleanup(() -> if (hooked) Pointer.hooks.remove(outside));
		return root;
	}

	static function modeOf(text:String):String
		return StringTools.startsWith(text, ">") ? "commands" : StringTools.startsWith(text, ":") ? "line" : StringTools.startsWith(text, "task ") ? "tasks" : "files";

	static final fileIds = ~/[^A-Za-z0-9]+/g;
	static inline var ROW = 36;
	static inline var CAPACITY = 13;

	function body(m:String):Element {
		choices = m == "pick" ? picker.items : m == "tasks" ? props.tasks() : props.actions;
		var catalog:Array<Choice> = m == "commands" || m == "tasks" || m == "pick" ? [for (a in choices) {
			id:"center-action-" + a.id, value:"action:" + a.id, label:a.label, detail:"", icon:a.icon, shortcut:a.shortcut == null ? "" : a.shortcut,
			search:((m == "commands" ? ">" : m == "tasks" ? "task " : "") + a.label + " " + a.id).toLowerCase()
		}] : [];
		var matching = Signal.make(([]:Array<Choice>)), selected = Signal.make(0);
		var empty = m == "pick" ? "Nothing matches" : m == "tasks" ? "No tasks match" : m == "line" ? "Type a line number, then Enter, to go to it" : m == "commands" ? "No commands match" : "No files match";
		var placeholder = m == "pick" ? picker.placeholder : m == "tasks" ? "Run a task" : m == "commands" ? "Run a command" : m == "line" ? "Go to line" : "Search files by name";
		var list = <div id="rayde-command-results" class="rayde-cc-list"/>;
		var scrolling = ashui.input.Scroll.attach(list.node, false, true);
		var first = Computed.make(() -> Std.int(Math.max(0, Math.min(matching.get().length - 1, Math.floor(scrolling.y.get() / ROW)) - 2)));
		var end = Computed.make(() -> Std.int(Math.min(matching.get().length, first.get() + CAPACITY)));
		var visible = Computed.make(() -> matching.get().slice(first.get(), end.get()));
		list.appendChild(<div height={Computed.make(() -> first.get() * 36.)} flexShrink={0}/>);
		list.appendChild(<for {row in visible}>${choiceRow(row, matching, selected)}</for>);
		list.appendChild(<div height={Computed.make(() -> (matching.get().length - end.get()) * 36.)} flexShrink={0}/>);
		list.appendChild(<if {matching.get().length == 0}><div class="rayde-cc-empty">${empty}</div></if>);
		function select(index:Int):Void {
			var count = matching.get().length;
			if (count == 0) return;
			index = Std.int(Math.max(0, Math.min(count - 1, index))); selected.set(index);
			var top = index * ROW, viewport = Math.min(292, count * ROW), y = scrolling.y.get();
			if (top < y) scrolling.jumpTo(0, top);
			else if (top + ROW > y + viewport) scrolling.jumpTo(0, top + ROW - viewport);
		}
		var element = <div class="flex flex-col" onKeyDown={e -> {
			var handled = true;
			switch e.key {
				case Named(ArrowDown): select(selected.get() + 1);
				case Named(ArrowUp): select(selected.get() - 1);
				case Named(PageDown): select(selected.get() + 8);
				case Named(PageUp): select(selected.get() - 8);
				case Named(Home): select(0);
				case Named(End): select(matching.get().length - 1);
				case Named(Enter):
					if (m == "line") goToLine();
					else if (matching.get().length > 0) choose(matching.get()[selected.get()].value);
				case _: handled = false;
			}
			if (handled) { e.preventDefault(); e.stopPropagation(); }
		}}>
		<div id="rayde-command-list" class="rayde-cc">
			<div class="rayde-cc-input"><icon document={Icons.SEARCH_LINE} class="rayde-cc-search"/><input ref={input} id="rayde-command-input" class="rayde-cc-field" placeholder={placeholder}/></div>
			${list}
		</div>
		<div class="rayde-cc-footer flex items-center gap-4 px-4">
			<if {m == "pick"}><text class="text-xs text-text-tertiary">Enter to choose</text>
			<else>
				<text class="text-xs text-text-tertiary">Enter to open</text>
				<text class="text-xs text-text-tertiary">&gt; for commands</text>
				<text class="text-xs text-text-tertiary">: for a line</text>
				<text class="text-xs text-text-tertiary">task for tasks</text>
			</if>
		</div>
		</div>;
		var field = ashui.ui.Input.at(element.tree, Css.query(element.tree, element.node.id, "#rayde-command-input")[0]);
		field.value.set(carry);
		function filter(q:String):Void {
			var words = [for (word in StringTools.trim(q).toLowerCase().split(" ")) if (word != "") word];
			matching.set(words.length == 0 ? catalog : [for (item in catalog) if (Lambda.foreach(words, word -> item.search.indexOf(word) >= 0)) item]);
			selected.set(0); scrolling.jumpTo(0, 0);
		}
		if (m == "files") {
			if (props.refreshFiles != null) props.refreshFiles();
			new Watch(() -> props.files(), paths -> {
				catalog = [for (path in paths) fileChoice(path)]; filter(field.value.get());
			});
		}
		new Watch(() -> field.value.get(), q -> {
			var next = modeOf(q);
			if (picker == null && next != mode.get()) { carry = q; mode.set(next); }
			else filter(q);
		});
		restoreFilter();
		return element;
	}

	function fileChoice(path:String):Choice {
		var name = haxe.io.Path.withoutDirectory(path), relative = shown(path);
		return {id:"center-file-" + fileIds.replace(relative, "-"), value:path, label:name, detail:haxe.io.Path.directory(relative),
			icon:Icons.HAXE, shortcut:"", search:(path + " " + name + " " + relative).toLowerCase()};
	}

	function choiceRow(row:Choice, matching:Signal<Array<Choice>>, selected:Signal<Int>):Element {
		var box = <div id={row.id} class="rayde-cc-item shrink-0" height={ROW} onPointerEnter={_ -> selected.set(matching.get().indexOf(row))} onClick={_ -> choose(row.value)}>
			<div class="flex items-center gap-3 flex-1 min-w-0">
				<icon document={row.icon} class="size-4 shrink-0 text-text-secondary"/>
				<text class="rayde-cc-label text-sm shrink-0">${row.label}</text>
				<text class="rayde-cc-detail text-xs min-w-0" wrap={false}>${row.detail}</text>
			</div>
			<if {row.shortcut != ""}><text class="rayde-cc-detail ml-auto text-xs shrink-0" wrap={false}>${row.shortcut}</text></if>
		</div>;
		Identity.of(box.tree, box.node.id).bindBooleanAttribute("data-selected", Computed.make(() -> matching.get()[selected.get()] == row));
		return box;
	}

	/** `path` from the project's folder. */
	function shown(path:String):String {
		var root = haxe.io.Path.addTrailingSlash(props.root);
		return StringTools.startsWith(path, root) ? path.substr(root.length) : path;
	}

	function choose(value:String):Void {
		if (StringTools.startsWith(value, "action:")) {
			var id = value.substr(7);
			var offered = choices;
			props.opened.set(false);
			for (a in offered)
				if (a.id == id)
					a.run();
		} else {
			props.opened.set(false);
			props.onOpenFile(value);
		}
	}

	function goToLine():Void {
		var text = input.get() == null ? "" : input.get().value.get();
		var line = Std.parseInt(StringTools.trim(text.substr(1)));
		if (line == null || line < 1)
			return;
		props.opened.set(false);
		props.onLine(line);
	}

	/** Once the list is laid out, puts the carried text in the filter and the cursor there. */
	function restoreFilter():Void {
		var hook:LayoutTree->Void = null;
		hook = tree -> {
			if (tree != panel.tree) return;
			LayoutTree.flushHooks.remove(hook);
			if (!props.opened.get() || input.get() == null)
				return;
			var field = ashui.ui.Input.at(panel.tree, Css.query(panel.tree, panel.node.id, "#rayde-command-input")[0]);
			if (field != null && field.value.get() != carry)
				field.value.set(carry);
			input.get().focus();
		};
		LayoutTree.flushHooks.push(hook);
		Owner.onCleanup(() -> LayoutTree.flushHooks.remove(hook));
	}
}
