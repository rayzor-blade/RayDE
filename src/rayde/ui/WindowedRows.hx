package rayde.ui;

import ashui.input.Scroll;
import ashui.layout.Element;
import ashui.reactive.Computed;

/** Fixed-height rows with spacer geometry; only the viewport and overscan own elements. */
class WindowedRows {
	public static function make<T>(id:String, classes:String, items:Array<T>, rowHeight:Int, maxHeight:Int, render:T->Element, empty:String):Element {
		if (items.length == 0) {
			var emptyBox = <div id={id} class="flex flex-col overflow-auto"><div class="px-3 py-3"><text class="text-xs text-text-tertiary">${empty}</text></div></div>;
			ashui.css.Identity.of(emptyBox.tree, emptyBox.node.id).addClasses([classes]);
			return emptyBox;
		}
		var height = Std.int(Math.min(maxHeight, items.length * rowHeight));
		var box = <div id={id} class="flex flex-col overflow-auto" height={height}/>;
		ashui.css.Identity.of(box.tree, box.node.id).addClasses([classes]);
		var scroll = Scroll.attach(box.node, false, true), overscan = 3;
		var capacity = Std.int(Math.ceil(height / rowHeight)) + 2 * overscan + 1;
		var first = Computed.make(() -> Std.int(Math.max(0, Math.min(items.length - 1, Math.floor(scroll.y.get() / rowHeight)) - overscan)));
		var end = Computed.make(() -> Std.int(Math.min(items.length, first.get() + capacity)));
		var shown = Computed.make(() -> items.slice(first.get(), end.get()));
		box.appendChild(<div height={Computed.make(() -> first.get() * rowHeight * 1.)} flexShrink={0}/>);
		box.appendChild(<for {item in shown}>${render(item)}</for>);
		box.appendChild(<div height={Computed.make(() -> (items.length - end.get()) * rowHeight * 1.)} flexShrink={0}/>);
		return box;
	}
}
