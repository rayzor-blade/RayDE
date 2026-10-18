package rayde.ui;

import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.draw.DrawContext;
import ashui.draw.Path;
import ashui.layout.Element;
import ashui.reactive.Signal;
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
	onClose:String->Void
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

	function render():Element
		return <div id="rayde-file-tabs" class="rayde-strip flex items-end px-1 shrink-0" height={HEIGHT}>
			<for {k in [{files: props.files.get(), front: props.active.get(), dirty: props.dirty.get()}]}>${strip(k.files, k.front, k.dirty)}</for>
		</div>;

	function strip(files:Array<String>, front:String, dirty:Array<String>):Element
		return <div class="flex items-end">{tabs(files, front, dirty)}</div>;

	function tabs(files:Array<String>, front:String, dirty:Array<String>):Array<Element>
		return [for (file in files) tab(file, file == front, dirty.indexOf(file) >= 0)];

	function tab(file:String, selected:Bool, edited:Bool):Element {
		var name = haxe.io.Path.withoutDirectory(file), id = "rayde-tab-" + ~/[^A-Za-z0-9]+/g.replace(name, "-");
		var element = <div id={id} class="rayde-tab relative flex items-center cursor-pointer" height={HEIGHT - 4} onClick={_ -> props.active.set(file)}>
			<if {selected}><canvas position={Absolute} left={0} top={0} widthPercent={1} heightPercent={1} pointerEvents={PointerEvents.None} draw={notch}/></if>
			<div class="rayde-tab-body relative flex items-center gap-2 px-2">
				<icon document={Icons.HAXE} class="rayde-tab-icon size-4"/>
				<text class="rayde-tab-name text-sm">${name}</text>
				<tooltip label="Close">
					<div id={id + "-close"} class="rayde-close flex items-center justify-center rounded-md" width={22} height={22}
						onClick={e -> { e.stopPropagation(); props.onClose(file); }}>
						<div class="rayde-dirty rounded-full" width={8} height={8}/>
						<icon document={Icons.CLOSE_LINE} class="rayde-close-icon size-3.5"/>
					</div>
				</tooltip>
			</div>
		</div>;
		// State the stylesheet reads: a class list has to be a literal, an attribute does not.
		var identity = ashui.css.Identity.of(element.tree, element.node.id);
		if (selected)
			identity.setAttribute("data-front", "");
		if (edited)
			identity.setAttribute("data-dirty", "");
		return element;
	}

	/** The front tab's shape and its flaring feet, filling the tab's box, whose sides keep a sweep clear for the feet. */
	function notch(ctx:DrawContext):Void {
		var theme = ThemeState.get();
		theme.revision.get();
		var s:Float = SWEEP, r:Float = ROUND, w = ctx.width - 2 * s, h = ctx.height;
		var path = new Path();
		path.moveTo(0, h);
		path.quadTo(s, h, s, h - s);
		path.lineTo(s, r);
		path.quadTo(s, 0, s + r, 0);
		path.lineTo(s + w - r, 0);
		path.quadTo(s + w, 0, s + w, r);
		path.lineTo(s + w, h - s);
		path.quadTo(s + w, h, s + w + s, h);
		path.close();
		ctx.fillPath(path, Brush.solid(theme.color(Surface).rgb()));
	}
}
