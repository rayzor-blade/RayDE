package rayde.ui;

import ashui.components.Command;
import ashui.components.Dialog;
import ashui.components.Icon;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.reactive.Signal;
import ashui.reactive.Watch;
import ashui.ui.Component;
import ashui.ui.Ref;

typedef QuickOpenProps = {
	opened:Signal<Bool>,
	/** The project's files as paths, asked for each time the list opens, so new files show. */
	files:Void->Array<String>,
	/** The folder the listed paths are shown relative to. */
	root:String,
	onOpen:String->Void
};

/**
 * Go to file: a filter over the project's files in a dialog, as VS Code's quick
 * open. Typing narrows by file name and by folder; Enter opens the highlighted
 * file. Command indexes its items when they are made, so the list is made again
 * each time the dialog opens.
 */
class QuickOpen extends Component<QuickOpenProps> {
	final filter = new Ref<CommandInput>();
	final openings = Signal.make(0);

	function render():Element {
		new Watch(() -> props.opened.get(), open -> if (open) {
			openings.set(openings.get() + 1);
			focusFilter();
		});
		return <dialog open={props.opened}>
			<dialog-content id="rayde-quick-open" size={Md}>
				<for {k in [openings.get()]}>${palette(k)}</for>
			</dialog-content>
		</dialog>;
	}

	function palette(_:Int):Element {
		var rows:Array<Element> = [new CommandEmpty({}, [new ashui.ui.Text("No files match")])];
		for (path in props.files())
			rows.push(row(path));
		return <command id="rayde-quick-open-list" onSelect={choose}>
			<command-input ref={filter} id="rayde-quick-open-filter" placeholder="Go to file…"/>
			${new CommandList({}, rows)}
		</command>;
	}

	function row(path:String):Element {
		var name = haxe.io.Path.withoutDirectory(path), relative = haxe.io.Path.directory(shown(path));
		return <command-item id={"quick-open-" + ~/[^A-Za-z0-9]+/g.replace(shown(path), "-")} value={path} keywords={[name, shown(path)]}>
			<div class="flex items-center gap-3 w-full min-w-0" height={32}>
				<icon document={Icons.HAXE} class="size-4 shrink-0"/>
				<text class="text-sm shrink-0">${name}</text>
				<text class="text-xs text-text-tertiary">${relative}</text>
			</div>
		</command-item>;
	}

	/** `path` from the project's folder. */
	function shown(path:String):String {
		var root = haxe.io.Path.addTrailingSlash(props.root);
		return StringTools.startsWith(path, root) ? path.substr(root.length) : path;
	}

	function choose(path:String):Void {
		props.opened.set(false);
		props.onOpen(path);
	}

	/** Puts the cursor in the filter once the dialog has been laid out. */
	function focusFilter():Void {
		var hook:LayoutTree->Void = null;
		hook = _ -> {
			LayoutTree.flushHooks.remove(hook);
			if (props.opened.get() && filter.get() != null)
				filter.get().focus();
		};
		LayoutTree.flushHooks.push(hook);
	}
}
