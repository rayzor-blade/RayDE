package rayde.ext;

import ashui.css.Identity;
import ashui.layout.Node;
import ashui.layout.Prop;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.ui.Text;
import rayde.ext.CanvasScene.CanvasLabel;

private typedef LabelSlot = {owner:Owner, element:Text, text:Signal<String>};

/** Visible, pooled text runs use Ashui's glyph atlas instead of tessellated glyph outlines. */
class CanvasLabels {
	final parent:Node;
	final scope:Owner;
	final slots:Array<LabelSlot> = [];
	final baselines = new Map<String, Float>();
	var previous:CanvasScene;
	var offsetX = Math.NaN;
	var offsetY = Math.NaN;
	var width = -1.;
	var height = -1.;

	public function new(parent:Node, scope:Owner) {
		this.parent = parent;
		this.scope = scope;
	}

	public function update(scene:CanvasScene, x:Float, y:Float, w:Float, h:Float):Bool {
		if (scene == previous && x == offsetX && y == offsetY && w == width && h == height) return false;
		previous = scene; offsetX = x; offsetY = y; width = w; height = h;
		var used = 0;
		for (label in scene.labels) {
			if (label.y + label.size * .5 < y || label.y - label.size > y + h || label.x > x + w || label.x + label.text.length * label.size < x) continue;
			if (used == slots.length) scope.run(() -> {
				var owner = new Owner();
				slots.push(owner.run(() -> {
					var text = Signal.make(""), element = new Text(text, {wrap:false});
					Identity.of(element.tree, element.node.id).addClasses(["rayde-canvas-label"]).setInline("position", "absolute").setInline("pointer-events", "none")
						.setInline("font-family", "system-ui").setInline("line-height", "1");
					element.tree.addChild(parent.id, element.node.id);
					return {owner:owner, element:element, text:text};
				}));
			});
			var slot = slots[used++], identity = Identity.of(slot.element.tree, slot.element.node.id);
			slot.text.set(label.text);
			identity.setInline("display", "flex").setInline("font-size", label.size + "px").setInline("font-weight", Std.string(label.weight));
			var color:Dynamic = label.ink.color;
			identity.setInline("color", Std.isOfType(color, String) ? "var(--" + ~/([a-z])([A-Z])/g.replace(Std.string(color), "$1-$2").toLowerCase() + ")" : "#" + StringTools.hex(cast color, 6));
			identity.setInline("opacity", Std.string(label.ink.alpha));
			slot.element.node.set(Prop.Left, (label.x:Single));
			slot.element.node.set(Prop.Top, (label.y - baseline(label):Single));
		}
		for (i in used...slots.length) Identity.of(slots[i].element.tree, slots[i].element.node.id).setInline("display", "none");
		while (slots.length > Std.int(Math.max(16, used * 2))) slots.pop().owner.dispose();
		return true;
	}

	function baseline(label:CanvasLabel):Float {
		var key = label.size + ":" + label.weight;
		if (!baselines.exists(key)) {
			var outline = ashui.draw.GlyphOutlines.of("Mg", {size:label.size, weight:label.weight});
			baselines.set(key, outline == null ? label.size * .8 : (label.size + outline.ascent - outline.descent) / 2);
		}
		return baselines.get(key);
	}
}
