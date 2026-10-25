package rayde.ui;

import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.draw.DrawContext;
import ashui.css.Css;
import ashui.draw.Path;
import ashui.input.Interaction;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Signal;
import ashui.reactive.Computed;
import ashui.reactive.Watch;
import ashui.theme.ThemeState;
import ashui.types.Brush;
import ashui.types.Style;
import ashui.ui.Component;

typedef FileTabsProps = {
	/** The open files, as paths, in tab order. */
	files:Signal<Array<String>>,
	/** The path of the tab in front. */
	active:Signal<String>,
	/** The files with edits not yet saved. */
	dirty:Signal<Array<String>>,
	onClose:String->Void,
	?onActivate:String->Void,
	/** Secondary press on a tab, in window coordinates. */
	?onContextMenu:(String, Float, Float)->Void,
	?drag:EditorTabDrag,
	?group:rayde.ui.EditorGroups.EditorGroup,
	/** What a tab says and shows for the entry `file`, which is a path or one of the workbench's own pages. */
	label:String->String,
	icon:String->ashui.svg.SvgDocument,
	/** What sits at the strip's far end: the editor's actions menu. */
	trailing:Element
};

/**
 * The open files as notched tabs. The tab in front has rounded top corners and
 * lower corners that sweep outward into the strip, in the colour of the page
 * under it, so it reads as part of that page. The others stay quiet until the
 * pointer is over them. A tab shows its close button in front and under the
 * pointer; a file with unsaved edits shows a dot there until the pointer is
 * over it.
 */
class FileTabs extends Component<FileTabsProps> {
	/** How far the front tab's lower corners sweep out, which the tab keeps clear on each side, and how round its upper ones are. */
	static inline var SWEEP = 12;

	static inline var ROUND = 11;
	static inline var HEIGHT = 40;

	/** Segments to a corner. */
	static inline var STEPS = 12;

	var scroller:Element;
	var revealHook:Null<LayoutTree->Void>;

	function render():Element {
		scroller = <div id="rayde-tab-scroll" class="rayde-tab-scroll flex flex-1 min-w-0 items-end overflow-x-auto" height={HEIGHT}>
			<div class="flex items-end gap-1 shrink-0">
				<for {file in props.files}>${tab(file)}</for>
				<div class="shrink-0" width={SWEEP}/>
			</div>
		</div>;
		new Watch(() -> {props.files.get(); props.active.get(); if (props.drag != null) props.drag.file.get(); 0;}, _ -> reveal(), (_, _) -> false);
		ashui.reactive.Owner.onCleanup(cancelReveal);
		// A mouse wheel only moves up and down, which scrolls a row of tabs along.
		Interaction.of(scroller.node).onWheel(e -> {
			var scroll = ashui.input.Scroll.of(scroller.node);
			if (scroll != null && e.deltaX == 0 && e.deltaY != 0)
				scroll.scrollTo(scroll.x.get() + e.deltaY, 0);
		});
		return <div id="rayde-file-tabs" class="rayde-strip flex items-end px-1 shrink-0" height={HEIGHT}>
			${scroller}
			<div class="rayde-strip-actions flex items-center shrink-0 pr-1" height={HEIGHT - 4}>{props.trailing}</div>
		</div>;
	}

	/** Scrolls the row of tabs so the tab in front shows, once layout has placed it. */
	function reveal():Void {
		cancelReveal();
		if (props.drag != null && props.drag.file.get() != "") return;
		var tries = 0, hook:LayoutTree->Void = null;
		hook = tree -> {
			var front = Css.query(scroller.tree, scroller.node.id, ".rayde-tab[data-front]");
			var scroll = ashui.input.Scroll.of(scroller.node);
			var box = front.length == 0 ? null : scroller.tree.getScrolledBounds(new Node(front[0])), view = scroller.tree.getScrolledBounds(scroller.node);
			// A tab not yet laid out reads as no width at all.
			if (box == null || box.width <= 0 || view == null || scroll == null) {
				if (++tries > 20)
					cancelReveal();
				return;
			}
			cancelReveal();
			var left = box.x - view.x, right = left + box.width;
			if (left < 0)
				scroll.scrollTo(scroll.x.get() + left - 8, 0);
			else if (right > view.width)
				scroll.scrollTo(scroll.x.get() + right - view.width + 8, 0);
		};
		LayoutTree.flushHooks.push(hook);
		revealHook = hook;
	}

	function cancelReveal():Void {
		if (revealHook == null) return;
		var hooks=LayoutTree.flushHooks;
		for (i in 0...hooks.length) if (Reflect.compareMethods(hooks[i],revealHook)) { hooks.splice(i,1); break; }
		revealHook=null;
	}

	function tab(file:String):Element {
		var selected = Computed.make(() -> props.active.get() == file);
		var name = Computed.make(() -> { props.files.get(); props.label(file); });
		var id = "rayde-tab-" + ~/[^A-Za-z0-9]+/g.replace(name.get(), "-");
		var element = <div id={id} class="rayde-tab relative flex items-center cursor-pointer" height={HEIGHT - 4}
			onPointerDown={event -> {
				if (event.button != null && event.button.match(Right) && props.onContextMenu != null) {
					event.preventDefault(); event.stopPropagation();
					if (props.drag != null) props.drag.cancel();
					props.onContextMenu(file,event.x,event.y);
				} else if (props.drag != null && props.group != null) props.drag.begin(props.group,file,event);
			}}
			onClick={_ -> { if (props.drag == null || !props.drag.suppressClick()) { if (props.onActivate != null) props.onActivate(file); else props.active.set(file); } }}>
			<if {selected.get()}><canvas position={Absolute} left={0} top={0} widthPercent={1} heightPercent={1} pointerEvents={PointerEvents.None} draw={ctx -> notch(ctx, props.files.get()[0] == file)}/></if>
			<div class="rayde-tab-body relative flex items-center gap-2 pl-2 pr-1">
				<icon document={props.icon(file)} class="rayde-tab-icon size-4"/>
				<text class="rayde-tab-name text-sm">${name.get()}</text>
				<tooltip label="Close">
					<div id={id + "-close"} class="rayde-close flex items-center justify-center rounded-md corner-squircle" width={22} height={22}
						onClick={e -> { e.stopPropagation(); props.onClose(file); }}>
						<div class="rayde-dirty rounded-full" width={8} height={8}/>
						<icon document={Icons.CLOSE_LINE} class="rayde-close-icon size-3.5"/>
					</div>
				</tooltip>
			</div>
		</div>;
		// State the stylesheet reads: a class list has to be a literal, an attribute does not.
		var identity = ashui.css.Identity.of(element.tree, element.node.id);
		identity.setAttribute("data-tab-file",file);
		if (props.drag != null) identity.bindBooleanAttribute("data-dragging",Computed.make(() -> props.drag.file.get() == file));
		identity.bindBooleanAttribute("data-front", selected);
		identity.bindBooleanAttribute("data-dirty", Computed.make(() -> props.dirty.get().indexOf(file) >= 0));
		identity.bindBooleanAttribute("data-first", Computed.make(() -> props.files.get()[0] == file));
		return element;
	}

	/**
	 * The front tab's shape: rounded top corners and lower corners that sweep out
	 * into the strip, each a quarter of the theme's superellipse, so they curve
	 * as the cards beside them do. The first tab has nothing to its left to
	 * flare into, so its left side goes straight down. The canvas fills the
	 * tab's box, which keeps a sweep clear on each side that has a foot.
	 */
	static function notch(ctx:DrawContext, first:Bool, outlined = false):Void {
		var theme = ThemeState.get();
		theme.revision.get();
		var k = theme.shape().effectiveMathExponent();
		var inset = outlined ? .5 : 0.;
		var s:Float = SWEEP, r:Float = ROUND, full = ctx.width - 2 * inset, h = ctx.height - 2 * inset;
		if (outlined) ctx.pushTransform(new ashui.draw.Affine(1,0,0,1,inset,inset));
		var left = first ? 0. : s, right = full - s;
		var path = new Path();
		path.moveTo(0, h);
		if (!first)
			corner(path, 0, h - s, s, k, Math.PI / 2, 0);
		path.lineTo(left, r);
		corner(path, left + r, r, r, k, Math.PI, 1.5 * Math.PI);
		path.lineTo(right - r, 0);
		corner(path, right - r, r, r, k, 1.5 * Math.PI, 2 * Math.PI);
		path.lineTo(right, h - s);
		corner(path, full, h - s, s, k, Math.PI, Math.PI / 2);
		// Fills close implicitly; the outline stays open where the tab meets its page.
		if (!outlined) path.close();
		ctx.fillPath(path, Brush.solid(theme.color(Surface).rgb()));
		if (outlined) {
			ctx.strokePath(path,new ashui.draw.Stroke(1),theme.color(Border).toBrush());
			ctx.popTransform();
		}
	}

	/** The dragged tab uses the strip's shape above its captured page. */
	public static function preview(label:String, icon:ashui.svg.SvgDocument, dirty:Bool, first:Bool):Element {
		return <div id="rayde-tab-drag-label" class="rayde-tab-drag-label relative flex items-center" height={HEIGHT - 4} paddingLeft={first ? 0 : SWEEP} paddingRight={SWEEP}>
			<canvas position={Absolute} left={0} top={0} widthPercent={1} heightPercent={1} pointerEvents={PointerEvents.None} draw={ctx -> notch(ctx,first,true)}/>
			<div class="relative flex items-center gap-2 px-2 min-w-0">
				<icon document={icon} class="size-4 shrink-0"/><text class="text-sm truncate">${label}</text>
				<if {dirty}><div class="rounded-full bg-text-secondary shrink-0" width={8} height={8}/><else><icon document={Icons.CLOSE_LINE} class="size-3.5 text-text-tertiary shrink-0"/></if>
			</div>
		</div>;
	}

	/** Lines along the superellipse of exponent `k` and radius `r` about (cx, cy), from angle `from` to `to` (screen angles: y grows down). */
	static function corner(path:Path, cx:Float, cy:Float, r:Float, k:Float, from:Float, to:Float):Void {
		inline function pow(v:Float):Float
			return (v < 0 ? -1 : 1) * Math.pow(Math.abs(v), 2 / k);
		for (i in 1...STEPS + 1) {
			var a = from + (to - from) * i / STEPS;
			path.lineTo(cx + r * pow(Math.cos(a)), cy + r * pow(Math.sin(a)));
		}
	}
}
