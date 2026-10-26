package rayde.ui;

import ashui.animation.AnimationScheduler;
import ashui.components.Library;
import ashui.components.Icon;
import ashui.css.Identity;
import ashui.input.Focus;
import ashui.input.Interaction;
import ashui.input.Scroll;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.layout.Prop;
import ashui.reactive.Computed;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.reactive.Watch;
import ashui.ui.Component;
import ashui.ui.Div;
import ashui.ui.Svg;
import ashui.ui.Text;

/** One entry of a folder, as the workbench lists it. */
typedef ExplorerEntry = {name:String, path:String, directory:Bool};

typedef ExplorerTreeProps = {
	root:String,
	name:String,
	/** The entries of a folder, in the order they are shown. */
	entries:String->Array<ExplorerEntry>,
	/** The project's own file, the first row under the folder; null if it has none. */
	head:Void->Null<{path:String, icon:ashui.svg.SvgDocument}>,
	icon:String->ashui.svg.SvgDocument,
	ignored:String->Bool,
	/** Whether a folder starts open, when it has not been opened or closed yet. */
	opened:String->Bool,
	/** A folder's open state; the same signal for the same folder. */
	state:(String, Bool)->Signal<Bool>,
	selected:Signal<String>,
	onSelect:String->Void,
	onPress:ashui.input.Events.PointerEvent->Void,
	?onMove:(String, String)->Void,
	?canMove:Void->Bool,
	/** Changes when the folders must be read again. */
	revision:Void->Int
};

private typedef Row = {path:String, label:String, depth:Int, directory:Bool, icon:ashui.svg.SvgDocument, open:Null<Signal<Bool>>};

/**
	The Explorer's tree. It keeps the entries as a flat list of what is shown and mounts only the rows in view, with a few above
	and below, so a project with every folder open costs what the screen shows. Rows are the markup of Ashui's TreeView
	(`.ui-tree-item > .ui-tree-row`), so its stylesheet draws them; they carry their path in `data-path` and `data-ignored` when
	git ignores them. A closed folder holds nothing: its entries are listed again when it opens.
**/
class ExplorerTree extends Component<ExplorerTreeProps> {
	public static inline var ROW = 24;
	static inline var OVERSCAN = 3;
	static inline var INDENT = 11;
	static inline var BASE = 4;

	var chevron:Null<ashui.svg.SvgDocument>;
	var pendingReveal = 0;
	var revealSoon:Void->Void = () -> {};

	function render():Element {
		var viewHeight = Signal.make(600.);
		var cache = new Map<String, Row>(), listings = new Map<String, Array<ExplorerEntry>>(), listed = -1;
		var mounted = new Map<String, Interaction>();
		var cursor = "";
		function listing(dir:String):Array<ExplorerEntry> {
			var known = listings.get(dir);
			if (known == null) listings.set(dir, known = props.entries(dir));
			return known;
		}
		function rowOf(path:String, label:String, depth:Int, directory:Bool, icon:ashui.svg.SvgDocument, open:Null<Signal<Bool>>, fresh:Map<String, Row>):Row {
			var key = path + "\n" + depth + "\n" + label;
			var row = cache.get(key);
			if (row == null) row = {path:path, label:label, depth:depth, directory:directory, icon:icon, open:open};
			fresh.set(key, row);
			return row;
		}
		var rows = Signal.make(([]:Array<Row>)), selectedShown = false, building = false, owner = Owner.current;
		var watched = new haxe.ds.ObjectMap<Signal<Bool>, Bool>();
		function rebuild():Void {
			building = true;
			var revision = props.revision();
			if (revision != listed) { listed = revision; listings = new Map(); cache = new Map(); }
			var fresh = new Map<String, Row>(), out:Array<Row> = [], signals:Array<Signal<Bool>> = [];
			function folder(path:String):Signal<Bool> {
				var open = props.state(path, props.opened(path));
				signals.push(open);
				return open;
			}
			function walk(dir:String, depth:Int):Void
				for (entry in listing(dir)) {
					if (entry.directory) {
						var open = folder(entry.path);
						out.push(rowOf(entry.path, entry.name, depth, true, Icons.FOLDER_LINE, open, fresh));
						if (open.get()) walk(entry.path, depth + 1);
					} else out.push(rowOf(entry.path, entry.name, depth, false, props.icon(entry.path), null, fresh));
				}
			var top = props.state(props.root, true);
			signals.push(top);
			out.push(rowOf(props.root, props.name, 0, true, Icons.workspaceFolder(true), top, fresh));
			if (top.get()) {
				var head = props.head();
				if (head != null) out.push(rowOf(head.path, haxe.io.Path.withoutDirectory(head.path), 1, false, head.icon, null, fresh));
				walk(props.root, 1);
			}
			cache = fresh;
			// A folder that is closed, or no longer there, is listed again when it is next needed.
			var shown = new Map<String, Bool>();
			for (row in out) if (row.directory) shown.set(row.path, true);
			for (dir in [for (key in listings.keys()) key]) if (!shown.exists(dir)) listings.remove(dir);
			for (open in signals) if (!watched.exists(open)) {
				watched.set(open, true);
				owner.run(() -> new Watch(() -> open.get(), _ -> if (!building) rebuild(), (_, _) -> false));
			}
			rows.set(out);
			// A selection that comes into the list, as when its folder opens, is brought into view once the rows are laid out.
			var present = false;
			for (row in out) if (row.path == props.selected.get()) { present = true; break; }
			if (present && !selectedShown) { pendingReveal = 8; revealSoon(); }
			selectedShown = present;
			building = false;
		}
		new Watch(() -> props.revision(), _ -> if (!building) rebuild(), (_, _) -> false);
		rebuild();
		var box = <div id="rayde-explorer-scroll" class="flex flex-col flex-1 min-h-0 overflow-auto pl-1 pr-2 pb-2" onPointerDown={props.onPress}/>;
		var scroll = Scroll.attach(box.node, false, true);
		var drag = new ExplorerDrag(box, props.root, scroll, (x,y) -> {
			var bounds = box.tree.getScrolledBounds(box.node);
			if (bounds == null || x < bounds.x || x >= bounds.x+bounds.width || y < bounds.y || y >= bounds.y+bounds.height
				|| !Lambda.exists(box.tree.hitTest(x,y), hit -> hit.id == box.node.id)) return null;
			var at = Std.int(Math.floor((y-bounds.y+scroll.y.get())/ROW)), all = rows.get();
			return at >= 0 && at < all.length ? {path:all[at].path,directory:all[at].directory} : {path:props.root,directory:true};
		}, path -> props.state(path, true).set(true), (from,dir) -> if (props.onMove != null) props.onMove(from,dir));
		Owner.onCleanup(drag.cancel);
		var capacity = Computed.make(() -> Std.int(Math.ceil(viewHeight.get() / ROW)) + 2 * OVERSCAN + 1);
		var first = Computed.make(() -> Std.int(Math.max(0, Math.min(rows.get().length - 1, Math.floor(scroll.y.get() / ROW)) - OVERSCAN)));
		var end = Computed.make(() -> Std.int(Math.min(rows.get().length, first.get() + capacity.get())));
		var visible = Computed.make(() -> rows.get().slice(first.get(), end.get()));
		var list = <div id="rayde-tree" class="ui-tree flex flex-col shrink-0"/>;
		Identity.of(list.tree, list.node.id).setAttribute("data-guides", "");
		var tree = list.tree;
		var live = true;
		var layout:LayoutTree->Bool = t -> {
			if (!live || t != tree) return false;
			var bounds = t.getBounds(box.node);
			if (bounds == null || bounds.height <= 0) return false;
			if (viewHeight.get() == bounds.height) return false;
			viewHeight.set(bounds.height);
			return true;
		};
		LayoutTree.layoutHooks.push(layout);
		Owner.onCleanup(() -> {
			live = false;
			for (i in 0...LayoutTree.layoutHooks.length) if (Reflect.compareMethods(LayoutTree.layoutHooks[i], layout)) { LayoutTree.layoutHooks.splice(i, 1); break; }
		});
		list.appendChild(<div height={Computed.make(() -> first.get() * ROW * 1.)} flexShrink={0}/>);
		list.appendChild(<for {row in visible}>${makeRow(row, mounted, path -> cursor = path, drag)}</for>);
		list.appendChild(<div height={Computed.make(() -> (rows.get().length - end.get()) * ROW * 1.)} flexShrink={0}/>);
		box.appendChild(list);

		function indexOf(path:String):Int {
			var all = rows.get();
			for (i in 0...all.length) if (all[i].path == path) return i;
			return -1;
		}
		function reveal(index:Int):Void {
			var top = index * ROW, height = viewHeight.get(), y = scroll.y.get();
			if (top < y) scroll.jumpTo(0, top);
			else if (top + ROW > y + height) scroll.jumpTo(0, top + ROW - height);
		}
		function settleReveal():Void {
			if (!live || pendingReveal <= 0) return;
			pendingReveal--;
			var at = indexOf(props.selected.get());
			if (at >= 0) reveal(at);
			if (pendingReveal > 0) AnimationScheduler.main.after(.016, settleReveal);
		}
		revealSoon = () -> AnimationScheduler.main.after(.016, settleReveal);
		function focusRow(path:String, attempts = 0):Void {
			var row = mounted.get(path);
			if (row != null) Focus.set(row, true);
			else if (live && attempts < 20) AnimationScheduler.main.after(.016, () -> focusRow(path, attempts + 1));
		}
		function go(index:Int):Void {
			var all = rows.get();
			if (all.length == 0) return;
			index = Std.int(Math.max(0, Math.min(all.length - 1, index)));
			cursor = all[index].path; reveal(index); focusRow(cursor);
		}
		Interaction.of(box.node).onKeyDown(e -> {
			if (drag.active() && e.key.match(Named(Escape))) { drag.abort(); e.preventDefault(); e.stopPropagation(); return; }
			var all = rows.get(), at = indexOf(cursor);
			if (at < 0) return;
			var row = all[at];
			switch e.key {
				case Named(ArrowDown): go(at + 1);
				case Named(ArrowUp): go(at - 1);
				case Named(PageDown): go(at + Std.int(Math.max(1, viewHeight.get() / ROW - 1)));
				case Named(PageUp): go(at - Std.int(Math.max(1, viewHeight.get() / ROW - 1)));
				case Named(Home): go(0);
				case Named(End): go(all.length - 1);
				case Named(ArrowRight):
					if (row.directory && !row.open.get()) row.open.set(true);
					else if (row.directory && at + 1 < all.length && all[at + 1].depth > row.depth) go(at + 1);
				case Named(ArrowLeft):
					if (row.directory && row.open.get()) row.open.set(false);
					else {
						var up = at - 1;
						while (up >= 0 && all[up].depth >= row.depth) up--;
						if (up >= 0) go(up);
					}
				case Named(Enter) | Named(Space):
					props.onSelect(row.path);
					if (row.directory) row.open.set(!row.open.get());
				case _: return;
			}
			e.preventDefault();
		});
		// The row of a file that comes forward is brought into view, when its folders are open.
		new Watch(() -> props.selected.get(), path -> {
			var at = indexOf(path);
			if (at >= 0) reveal(at);
		}, (_, _) -> false);
		return <div class="flex flex-col flex-1 min-h-0 relative">
			${box}
			<if {drag.file.get() != ""}><div class="rayde-explorer-drag" left={drag.x} top={drag.y}><icon document={Lambda.exists(rows.get(), row -> row.path == drag.file.get() && row.directory) ? Icons.FOLDER_LINE : props.icon(drag.file.get())} class="size-4 shrink-0"/><text wrap={false}>${haxe.io.Path.withoutDirectory(drag.file.get())}</text></div></if>
		</div>;
	}

	function makeRow(row:Row, mounted:Map<String, Interaction>, focused:String->Void, drag:ExplorerDrag):Element {
		var parts:Array<Element> = [];
		if (row.directory) {
			if (chevron == null)
				chevron = ashui.svg.SvgDocument.of(<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m9 18 6-6-6-6"/></svg>);
			var mark = new Svg(chevron, {width: 14, height: 14});
			Identity.of(mark.tree, mark.node.id).setClasses(["ui-tree-chevron"]);
			parts.push(mark);
		} else parts.push(Library.part("ui-tree-chevron-space", null, null, []));
		var icon = new Svg(row.icon, {width: 16, height: 16});
		Identity.of(icon.tree, icon.node.id).setClasses(["ui-tree-icon"]);
		parts.push(icon);
		parts.push(Library.part("ui-tree-label", null, null, [new Text(row.label, {wrap: false})]));
		var path = row.path, selected = props.selected;
		var line = Library.part("ui-tree-row", null, ["selected" => Computed.make(() -> (selected.get() == path ? "" : null : Null<String>))], parts);
		line.node.set(Prop.PaddingLeft, (BASE + row.depth * INDENT : Single));
		Identity.of(line.tree, line.node.id).setAttribute("role", "treeitem");
		var interaction = Interaction.of(line.node).setFocusable(true);
		interaction.onClick(_ -> {
			if (drag.suppressClick()) return;
			focused(path);
			props.onSelect(path);
			if (row.directory) row.open.set(!row.open.get());
		});
		interaction.onPointerDown(event -> if (props.onMove != null && (props.canMove == null || props.canMove())) drag.begin(path, event));
		var rowIdentity = Identity.of(line.tree, line.node.id);
		new Watch(() -> drag.target.get() == path, on -> rowIdentity.setAttribute("data-drop-target", on ? "" : null));
		new Watch(() -> drag.file.get() == path, on -> rowIdentity.setAttribute("data-drag-source", on ? "" : null));
		interaction.onFocus(_ -> focused(path));
		mounted.set(path, interaction);
		Owner.onCleanup(() -> if (mounted.get(path) == interaction) mounted.remove(path));
		var item = Library.part("ui-tree-item", null, row.directory ? ["state" => Computed.make(() -> (row.open.get() ? "open" : "closed" : Null<String>))] : null, [line]);
		var identity = Identity.of(item.tree, item.node.id);
		identity.setAttribute("data-path", path);
		if (props.ignored(path)) identity.setAttribute("data-ignored", "");
		return item;
	}
}
