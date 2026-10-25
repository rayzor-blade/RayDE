package rayde.ui;

import ashui.animation.AnimationScheduler;
import ashui.components.ContextMenu;
import ashui.components.ContextMenu.ContextMenuTrigger;
import ashui.input.Clipboard;
import ashui.input.Interaction;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.reactive.Watch;
import ashui.ui.Component;
import ashui.ui.Ref;
import rayde.ui.EditorGroups.EditorGroup;

typedef TabContextMenuProps = {
	workbench:Workbench,
	group:EditorGroup,
	label:String->String,
	icon:String->ashui.svg.SvgDocument,
	trailing:Element
};

/** One lazy context menu per strip; opening it does not load an inactive tab. */
@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.EditorPart)
@:access(rayde.ui.workbench.MenusPart)
class TabContextMenu extends Component<TabContextMenuProps> {
	final opened = Signal.make(false);
	final target = Signal.make("");
	final menu = new Ref<ContextMenu>();
	var pending:Null<Void->Void>;
	var selection:Null<{
		file:String,
		editor:ashui.components.CodeEditor,
		anchor:Int,
		caret:Int,
		text:String
	}>;

	function render():Element {
		var wb = props.workbench,
			group = props.group,
			trigger = new Ref<ContextMenuTrigger>();
		var view = <context-menu ref={menu} open={opened} class="rayde-tab-context flex shrink-0 min-w-0">
			<context-menu-trigger ref={trigger} class="flex flex-1 min-w-0">
				<file-tabs files={group.files} active={group.active} dirty={wb.dirty} drag={wb.editorPart.tabDrag} group={group}
					onActivate={file -> wb.editorPart.groups.select(group,file)} onClose={file -> { wb.editorPart.groups.select(group); wb.closeFile(file); }}
					onContextMenu={(file,x,y) -> { if (opened.get()) opened.set(false); rememberSelection(); target.set(file); menu.get().openAt(x,y); }} label={props.label} icon={props.icon} trailing={props.trailing} class="flex-1 min-w-0"/>
			</context-menu-trigger>
			<context-menu-content id="rayde-tab-context-menu"><if {opened.get()}>${items(target.get() == "" ? group.active.get() : target.get())}</if></context-menu-content>
		</context-menu>;
		Interaction.of(trigger.get().node).setFocusable(false);
		new Watch(() -> opened.get(), on -> {
			restoreSelection();
			if (on && target.get() == "" && group.active.get() == "")
				opened.set(false);
			else if (!on) {
				target.set("");
				selection = null;
				var action = pending;
				pending = null;
				if (action != null)
					AnimationScheduler.main.after(0, action);
			}
		});
		new Watch(() -> group.files.get(), files -> {
			if (opened.get() && target.get() != "" && files.indexOf(target.get()) < 0)
				opened.set(false);
		});
		return view;
	}

	function rememberSelection():Void {
		var wb = props.workbench,
			file = wb.active.get(),
			editor = wb.editorOf(file);
		selection = editor == null ? null : {
			file: file,
			editor: editor,
			anchor: editor.editing.anchor.get(),
			caret: editor.editing.caret.get(),
			text: editor.value.get()
		};
	}

	function restoreSelection():Void {
		var saved = selection;
		if (saved != null && props.workbench.editorOf(saved.file) == saved.editor && saved.editor.value.get() == saved.text)
			saved.editor.select(saved.anchor, saved.caret);
	}

	function run(file:String, action:Void->Void):Void {
		// Dispatch after the floating menu has restored the previous editor's focus.
		pending = () -> {
			var wb = props.workbench;
			if (wb.gone || wb.open.get().indexOf(file) < 0)
				return;
			try
				action()
			catch (error:Dynamic)
				wb.say(Std.string(error));
		};
	}

	function activate(file:String):Void {
		var groups = props.workbench.editorPart.groups,
			owner = groups.owner(file);
		if (owner != null)
			groups.select(owner, file);
	}

	function close(file:String, mode:String):Void {
		var wb = props.workbench, owner = wb.editorPart.groups.owner(file);
		if (owner == null)
			return;
		var files = owner.files.get().copy(), index = files.indexOf(file);
		var selected = switch mode {
			case "others": files.filter(path -> path != file);
			case "left": files.slice(0, index);
			case "right": files.slice(index + 1);
			case "saved": files.filter(path -> wb.dirty.get().indexOf(path) < 0);
			case _: files;
		};
		for (path in selected)
			wb.closeFile(path);
	}

	function pathOf(file:String):Null<String>
		return file == Workbench.SETTINGS ? props.workbench.settingsFile() : props.workbench.realFile(file);

	function copyPath(path:String, relative:Bool):Void {
		var wb = props.workbench,
			root = haxe.io.Path.addTrailingSlash(wb.props.display.cwd);
		Clipboard.setText(relative && StringTools.startsWith(path, root) ? path.substr(root.length) : path);
		wb.say(relative ? "Copied the relative path" : "Copied the path");
	}

	function items(file:String):Element {
		var wb = props.workbench,
			files = props.group.files.get(),
			index = files.indexOf(file),
			path = pathOf(file);
		var only = files.length < 2,
			oneGroup = wb.editorPart.groups.all().length < 2;
		var saved = [for (path in files) if (wb.dirty.get().indexOf(path) < 0) path];
		return <div class="flex flex-col">
			<context-menu-item id="rayde-tab-menu-close" onSelect={() -> run(file,() -> wb.closeFile(file))}>Close Tab</context-menu-item>
			<context-menu-item id="rayde-tab-menu-close-others" disabled={only} onSelect={() -> run(file,() -> close(file,"others"))}>Close Others</context-menu-item>
			<context-menu-item id="rayde-tab-menu-close-left" disabled={index <= 0} onSelect={() -> run(file,() -> close(file,"left"))}>Close Tabs to the Left</context-menu-item>
			<context-menu-item id="rayde-tab-menu-close-right" disabled={index < 0 || index >= files.length-1} onSelect={() -> run(file,() -> close(file,"right"))}>Close Tabs to the Right</context-menu-item>
			<context-menu-item id="rayde-tab-menu-close-saved" disabled={saved.length == 0} onSelect={() -> run(file,() -> close(file,"saved"))}>Close Saved Tabs</context-menu-item>
			<context-menu-item id="rayde-tab-menu-close-all" onSelect={() -> run(file,() -> close(file,"all"))}>Close All Tabs</context-menu-item>
			<context-menu-separator/>
			<context-menu-item id="rayde-tab-menu-split-right" onSelect={() -> run(file,() -> { activate(file); wb.editorPart.splitEditor("horizontal"); })}>Split Editor Right</context-menu-item>
			<context-menu-item id="rayde-tab-menu-split-down" onSelect={() -> run(file,() -> { activate(file); wb.editorPart.splitEditor("vertical"); })}>Split Editor Down</context-menu-item>
			<context-menu-item id="rayde-tab-menu-move" disabled={oneGroup} onSelect={() -> run(file,() -> { activate(file); wb.editorPart.moveEditor(); })}>Move to Next Group</context-menu-item>
			<context-menu-separator/>
			<context-menu-item id="rayde-tab-menu-save" disabled={Workbench.isVirtual(file) || wb.dirty.get().indexOf(file) < 0 || wb.contributions.readOnly(file)} onSelect={() -> run(file,() -> wb.runPart.saveFile(file))}>Save</context-menu-item>
			<context-menu-item id="rayde-tab-menu-copy-path" disabled={path == null} onSelect={() -> run(file,() -> copyPath(path,false))}>Copy Path</context-menu-item>
			<context-menu-item id="rayde-tab-menu-copy-relative" disabled={path == null} onSelect={() -> run(file,() -> copyPath(path,true))}>Copy Relative Path</context-menu-item>
			<context-menu-item id="rayde-tab-menu-reveal" disabled={path == null} onSelect={() -> run(file,() -> rayde.files.FileOps.reveal(path))}>${Sys.systemName() == "Mac" ? "Reveal in Finder" : "Reveal in File Manager"}</context-menu-item>
			${wb.menusPart.titleItems(file,action -> run(file,action))}
		</div>;
	}
}
