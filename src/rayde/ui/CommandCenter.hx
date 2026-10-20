package rayde.ui;

import ashui.components.Command;
import ashui.components.Floating;
import ashui.components.Icon;
import ashui.css.Css;
import ashui.input.Interaction;
import ashui.input.Pointer;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
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
	/** The project's files as paths, most recently opened first, asked for each time the center opens. */
	files:Void->Array<String>,
	/** The folder the listed paths are shown relative to. */
	root:String,
	actions:Array<CenterAction>,
	/** The project's tasks, which the center lists after `task `; asked for each time it opens. */
	tasks:Void->Array<CenterAction>,
	onOpenFile:String->Void,
	onLine:Int->Void
};

/**
 * The command center, as VS Code's: a panel under the title bar's project
 * pill, over the page and not instead of it, that goes to a file as typed, to a
 * command after `>`, and to a line after `:`. The page stays live under it; a
 * press outside, or Escape, closes it. Command indexes its items when they are
 * made, so the list is made again when the mode changes or the center opens.
 */
class CommandCenter extends Component<CommandCenterProps> {
	final command = new Ref<Command>();
	final input = new Ref<CommandInput>();
	final mode = Signal.make("files");
	final builds = Signal.make(0);
	final mounted = Signal.make(false);

	/** What the filter holds when the list is next made: what it was opened with, or what was typed across a change of mode. */
	var carry = "";

	var panel:Element;
	var floating:Floating;

	/** The list of choices the center was opened to pick from, or null when it goes to files and commands. */
	var picker:Null<Picker> = null;

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

	function body(m:String):Element {
		var rows:Array<Element> = switch m {
			case "pick": [for (a in picker.items) actionRow(a, "")];
			case "tasks": [for (a in props.tasks()) actionRow(a, "task ")];
			case "commands": [for (a in props.actions) actionRow(a, ">")];
			case "line": [];
			case _: [for (path in props.files()) fileRow(path)];
		};
		var empty = m == "pick" ? "Nothing matches" : m == "tasks" ? "No tasks match" : m == "line" ? "Type a line number, then Enter, to go to it" : m == "commands" ? "No commands match" : "No files match";
		rows.unshift(new CommandEmpty({}, [new ashui.ui.Text(empty)]));
		var placeholder = m == "pick" ? picker.placeholder : m == "tasks" ? "Run a task" : m == "commands" ? "Run a command" : m == "line" ? "Go to line" : "Search files by name";
		var element = <div class="flex flex-col">
		<command ref={command} id="rayde-command-list" onSelect={choose}>
			<command-input ref={input} id="rayde-command-input" placeholder={placeholder} onKeyDown={e -> if (m == "line" && e.key.match(Named(Enter))) {
				goToLine();
				e.preventDefault();
				e.stopPropagation();
			}}/>
			${new CommandList({}, rows)}
		</command>
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
		// A change of mode builds the list again, so what was typed goes back into the new filter.
		new Watch(() -> field.value.get(), q -> {
			var next = modeOf(q);
			if (picker == null && command.get() != null && next != mode.get()) {
				carry = q;
				mode.set(next);
			}
		});
		restoreFilter();
		return element;
	}

	function fileRow(path:String):Element {
		var name = haxe.io.Path.withoutDirectory(path), relative = shown(path);
		return <command-item id={"center-file-" + ~/[^A-Za-z0-9]+/g.replace(relative, "-")} value={path} keywords={[name, relative]}>
			<div class="flex items-center gap-3 w-full min-w-0" height={32}>
				<icon document={Icons.HAXE} class="size-4 shrink-0"/>
				<text class="text-sm shrink-0">${name}</text>
				<text class="text-xs text-text-tertiary">${haxe.io.Path.directory(relative)}</text>
			</div>
		</command-item>;
	}

	/** One action as a row; what is typed in the filter starts with `prefix` (> for commands, `task ` for tasks), which the row answers to. */
	function actionRow(a:CenterAction, prefix:String):Element
		return <command-item id={"center-action-" + a.id} value={"action:" + a.id} keywords={[prefix + a.label, a.label]} shortcut={a.shortcut}>
			<div class="flex items-center gap-3 w-full min-w-0" height={32}>
				<icon document={a.icon} class="size-4 shrink-0 text-text-secondary"/>
				<text class="text-sm">${a.label}</text>
			</div>
		</command-item>;

	/** `path` from the project's folder. */
	function shown(path:String):String {
		var root = haxe.io.Path.addTrailingSlash(props.root);
		return StringTools.startsWith(path, root) ? path.substr(root.length) : path;
	}

	function choose(value:String):Void {
		if (StringTools.startsWith(value, "action:")) {
			var id = value.substr(7);
			var choices = picker != null ? picker.items : mode.get() == "tasks" ? props.tasks() : props.actions;
			props.opened.set(false);
			for (a in choices)
				if (a.id == id)
					a.run();
		} else {
			props.opened.set(false);
			props.onOpenFile(value);
		}
	}

	function goToLine():Void {
		var text = command.get() == null ? "" : command.get().query.get();
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
