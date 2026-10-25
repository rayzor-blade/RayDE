package rayde.ui;

import ashui.animation.AnimationScheduler;
import ashui.components.CodeEditor;
import ashui.components.ContextMenu;
import ashui.components.ContextMenu.ContextMenuTrigger;
import ashui.components.Icon;
import ashui.input.Clipboard;
import ashui.input.Focus;
import ashui.input.Interaction;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.reactive.Watch;
import ashui.ui.Component;
import ashui.ui.Ref;

@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.EditorPart)
@:access(rayde.ui.workbench.ExtensionsPart)
@:access(rayde.ui.workbench.KeymapPart)
class EditorContextMenu extends Component<{workbench:Workbench, file:String, editor:CodeEditor}> {
	final opened = Signal.make(false);
	final menu = new Ref<ContextMenu>();
	var selection:{anchor:Int, caret:Int};
	var contextText:String;
	var contextOffset = 0;

	function render():Element {
		var editor = props.editor, trigger = new Ref<ContextMenuTrigger>();
		var view = <context-menu ref={menu} open={opened} class="rayde-code-context flex flex-col flex-1 min-h-0 min-w-0">
			<context-menu-trigger ref={trigger} class="flex flex-col flex-1 min-h-0 min-w-0">${editor}</context-menu-trigger>
			<context-menu-content id="rayde-code-context-menu"><if {opened.get()}>${items()}</if></context-menu-content>
		</context-menu>;
		// The floating menu restores the text editor's focus, rather than its wrapper's.
		Interaction.of(trigger.get().node).setFocusable(false);
		var wasOpen = false;
		new Watch(() -> opened.get(), on -> {
			if (on || wasOpen)
				restoreSelection();
			wasOpen = on;
		});
		new Watch(() -> editor.value.get(), _ -> {
			if (opened.get())
				opened.set(false);
		});
		editor.editing.interaction.onPointerDown(event -> {
			if (event.button == null || !event.button.match(Right))
				return;
			activate();
			var at = editor.offsetAt(event.x, event.y),
				selection = editor.editing.selectionRange();
			if (at >= 0 && !(selection.from < selection.to && at >= selection.from && at < selection.to))
				editor.select(at, at);
			rememberSelection();
			contextOffset = at < 0 ? editor.editing.caret.get() : at;
			Focus.set(editor.editing.interaction,false);
		});
		editor.editing.interaction.onKeyDown(event -> {
			var menuKey = event.key.match(Named(ContextMenu));
			var shiftF10 = event.shift && !event.control && !event.alt && !event.superKey && event.key.match(Named(F10));
			if (!menuKey && !shiftF10)
				return;
			// A preset may already use Shift+F10, as IntelliJ does for Run.
			if (!menuKey
				&& props.workbench.keymapPart.bindings.commandFor(rayde.keys.Chord.parse("shift+f10", Sys.systemName() == "Mac")) != null)
				return;
			event.preventDefault();
			event.stopPropagation();
			activate();
			rememberSelection();
			var box = editor.rectAt(editor.editing.caret.get());
			if (box != null)
				menu.get().openAt(box.x, box.y + box.height);
		});
		return view;
	}

	function rememberSelection():Void {
		selection = {anchor: props.editor.editing.anchor.get(), caret: props.editor.editing.caret.get()};
		contextText = props.editor.value.get();
		contextOffset = props.editor.editing.caret.get();
	}

	function restoreSelection():Void
		if (selection != null)
			props.editor.select(selection.anchor, selection.caret);

	function activate():Void {
		var groups = props.workbench.editorPart.groups,
			group = groups.owner(props.file);
		if (group != null)
			groups.select(group, props.file);
	}

	function run(action:Void->Void):Void {
		var range = selection, text = contextText;
		// A picker or prompt takes focus after the menu has restored its editor.
		AnimationScheduler.main.after(0, () -> {
			var wb = props.workbench;
			if (wb.gone || wb.editorOf(props.file) != props.editor || props.editor.value.get() != text)
				return;
			activate();
			props.editor.select(range.anchor, range.caret);
			action();
		});
	}

	function shortcut(command:String):Null<String> {
		props.workbench.keymapPart.bindingsRevision.get();
		return props.workbench.keymapPart.bindings.label(command);
	}

	function editKey(key:String, shift = false):String
		return (Sys.systemName() == "Mac" ? "⌘" : "Ctrl+") + (shift ? Sys.systemName() == "Mac" ? "⇧" : "Shift+" : "") + key;

	function languageItem(command:String, label:String):Element {
		var wb = props.workbench, offset = contextOffset;
		return <context-menu-item id={"rayde-code-menu-" + command} shortcut={shortcut(command)} disabled={!EditorCommands.available(wb,props.file,command)}
			onSelect={() -> run(() -> EditorCommands.run(wb,props.file,props.editor,command,offset))}>${label}</context-menu-item>;
	}

	function items():Element {
		var wb = props.workbench,
			editor = props.editor,
			readOnly = editor.editing.readOnly;
		var selection = editor.editing.selectionRange(),
			selected = selection.from < selection.to;
		return <div class="flex flex-col">
			${languageItem("definition","Go to Definition")}
			${languageItem("typedefinition","Go to Type Definition")}
			${languageItem("implementation","Go to Implementations")}
			${languageItem("references","Find All References")}
			<context-menu-separator/>
			${languageItem("renamesymbol","Rename Symbol…")}
			${languageItem("formatdocument","Format Document")}
			<context-menu-item id="rayde-code-menu-codeactions" shortcut={shortcut("codeactions")} onSelect={() -> run(wb.codeActionsPart.showCodeActions)}>Code Actions…</context-menu-item>
			${extensionItems()}
			<context-menu-separator/>
			<context-menu-item id="rayde-code-menu-undo" shortcut={editKey("Z")} disabled={readOnly || !DocumentHistory.canUndo(editor.state)} onSelect={() -> run(editor.undo)}>Undo</context-menu-item>
			<context-menu-item id="rayde-code-menu-redo" shortcut={Sys.systemName() == "Mac" ? editKey("Z",true) : editKey("Y")} disabled={readOnly || !DocumentHistory.canUndo(editor.state,true)} onSelect={() -> run(editor.redo)}>Redo</context-menu-item>
			<context-menu-separator/>
			<context-menu-item id="rayde-code-menu-cut" shortcut={editKey("X")} disabled={readOnly || !selected} onSelect={() -> run(() -> { Clipboard.setText(editor.editing.selection()); editor.editing.replace(""); })}>Cut</context-menu-item>
			<context-menu-item id="rayde-code-menu-copy" shortcut={editKey("C")} disabled={!selected} onSelect={() -> run(() -> Clipboard.setText(editor.editing.selection()))}>Copy</context-menu-item>
			<context-menu-item id="rayde-code-menu-paste" shortcut={editKey("V")} disabled={readOnly} onSelect={() -> run(() -> editor.editing.replace(Clipboard.text()))}>Paste</context-menu-item>
			<context-menu-item id="rayde-code-menu-selectall" shortcut={editKey("A")} onSelect={() -> run(() -> editor.select(0,editor.value.get().length))}>Select All</context-menu-item>
			<context-menu-separator/>
			<context-menu-item id="rayde-code-menu-find" shortcut={shortcut("find")} onSelect={() -> run(() -> editor.showFind())}>Find…</context-menu-item>
			<context-menu-item id="rayde-code-menu-replace" shortcut={shortcut("replace")} disabled={readOnly} onSelect={() -> run(() -> editor.showFind(true))}>Replace…</context-menu-item>
			<context-menu-item id="rayde-code-menu-commands" shortcut={shortcut("commands")} onSelect={() -> run(() -> wb.openCenter(">"))}>Command Palette…</context-menu-item>
		</div>;
	}

	function extensionItems():Element {
		var wb = props.workbench,
			entries = wb.extensionsPart.contributedMenu("editor/context", props.file, "file");
		var items:Array<Element> = [];
		if (entries.length > 0)
			items.push(<context-menu-separator/>);
		for (entry in entries) {
			var item = entry.item,
				manifest = entry.extension,
				icon = ViewIcons.named(manifest, item.icon);
			var label = icon == null ? <text>${item.title}</text> : <div class="flex items-center gap-3"><icon document={icon} class="size-4 shrink-0"/><text>${item.title}</text></div>;
			items.push(<context-menu-item id={"rayde-code-menu-ext-" + manifest.id + "-" + item.command} shortcut={shortcut(rayde.ui.workbench.ExtensionsPart.extensionKey(manifest.id,item.command))}
				onSelect={() -> run(() -> wb.extensionsPart.runExtensionCommand(manifest.id,item.command,props.file,props.editor.editing.selectionRange()))}>${label}</context-menu-item>);
		}
		return <div class="flex flex-col">{items}</div>;
	}
}
