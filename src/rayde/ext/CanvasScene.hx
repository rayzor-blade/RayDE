package rayde.ext;

import ashui.canvaskit.CanvasKit;
import ashui.draw.DrawContext;
import ashui.draw.Path;
import ashui.draw.Stroke;
import ashui.theme.ColorToken;
import ashui.theme.ThemeState;
import ashui.types.Brush;

private typedef Ink = {color:Dynamic, alpha:Float};
private typedef Region = {id:String, x:Float, y:Float, width:Float, height:Float};
private enum Drawing {
	Curve(path:Path, ink:Ink, width:Float, fill:Bool);
	Circle(x:Float, y:Float, radius:Float, ink:Ink, width:Float);
	Rect(x:Float, y:Float, w:Float, h:Float, radius:Float, ink:Ink, width:Float);
	Text(text:String, x:Float, y:Float, ink:Ink, size:Float, weight:Int);
}

/** A validated, retained drawing batch. No script or protocol work runs while painting. */
class CanvasScene {
	public final bounds:{x:Float, y:Float, width:Float, height:Float};
	final drawings:Array<Drawing> = [];
	final regions:Array<Region> = [];
	final brushes:Map<String, Brush> = [];
	var theme:Null<ThemeState>;

	public function new(value:Dynamic) {
		bounds = value == null || value.bounds == null ? {x: 0., y: 0., width: 1., height: 1.} : box(value.bounds);
		if (value == null) return;
		var segments = 0;
		for (op in list(value, "commands")) {
			var ink = ink(op), width = number(op, "stroke", 0, 0, 256);
			switch text(op, "type") {
				case "path":
					var path = new Path(), started = false;
					for (segment in list(op, "path")) {
						if (++segments > 50000) throw "Canvas path segment limit exceeded";
						if (!Std.isOfType(segment, Array)) throw "Canvas path segment must be an array";
						var a:Array<Dynamic> = segment;
						if (a.length == 0) throw "Canvas path segment is empty";
						function n(i:Int):Float {
							if (i >= a.length) throw "Canvas path segment is incomplete";
							return finite(a[i]);
						}
						switch (a[0] : String) {
							case "M" if (a.length == 3): path.moveTo(n(1), n(2)); started = true;
							case "L" if (started && a.length == 3): path.lineTo(n(1), n(2));
							case "C" if (started && a.length == 7): path.cubicTo(n(1), n(2), n(3), n(4), n(5), n(6));
							case "Z" if (started && a.length == 1): path.close();
							case _: throw "Unsupported canvas path segment";
						}
					}
					drawings.push(Curve(path, ink, width, width == 0));
				case "circle":
					drawings.push(Circle(number(op, "x"), number(op, "y"), number(op, "radius", 1, 0), ink, width));
				case "rect":
					var b = box(op);
					drawings.push(Rect(b.x, b.y, b.width, b.height, number(op, "radius", 0, 0), ink, width));
				case "text":
					drawings.push(Text(text(op, "text"), number(op, "x"), number(op, "y"), ink,
						number(op, "size", 13, 1, 256), Std.int(number(op, "weight", 400, 100, 900))));
				case _: throw "Unsupported canvas command";
			}
		}
		var ids = new Map<String, Bool>();
		for (r in list(value, "regions")) {
			var id = text(r, "id"), b = box(r);
			if (id == "" || ids.exists(id)) throw "Canvas region ids must be nonempty and unique";
			ids.set(id, true);
			regions.push({id: id, x: b.x, y: b.y, width: b.width, height: b.height});
		}
	}

	public function draw(ctx:DrawContext, kit:CanvasKit, ?hovered:String):Void {
		var current = ThemeState.get();
		if (current != theme) { brushes.clear(); theme = current; }
		var zoom = kit.viewport.zoom.get();
		for (r in regions)
			if (r.id == hovered) ctx.fillRect(r.x, r.y, r.width, r.height, brush({color: "textPrimary", alpha: .05}), 4);
		for (op in drawings)
			switch op {
				case Curve(path, ink, width, fill):
					if (fill) ctx.fillPath(path, brush(ink)); else ctx.strokePath(path, new Stroke(width / zoom), brush(ink));
				case Circle(x, y, r, ink, width):
					if (!kit.visible(x-r, y-r, 2*r, 2*r)) continue;
					if (width == 0) ctx.fillCircle(x, y, r, brush(ink)); else ctx.strokeCircle(x, y, r, new Stroke(width / zoom), brush(ink));
				case Rect(x, y, w, h, radius, ink, width):
					if (!kit.visible(x, y, w, h)) continue;
					if (width == 0) ctx.fillRect(x, y, w, h, brush(ink), radius); else ctx.strokeRect(x, y, w, h, new Stroke(width / zoom), brush(ink), radius);
				case Text(text, x, y, ink, size, weight):
					if (kit.visible(x, y-size, size * text.length, size*1.5)) ctx.text(text, x, y, brush(ink), {size: size, weight: weight});
			}
		// Keep all regions for full-scene fit and marquee selection, including offscreen rows.
		for (r in regions) kit.region(r.id, r.x, r.y, r.width, r.height);
	}

	function brush(ink:Ink):Brush {
		var color = Std.isOfType(ink.color, String) ? theme.color(cast ink.color).rgb() : (ink.color : Int);
		var key = color + ":" + ink.alpha;
		if (!brushes.exists(key)) {
			brushes.set(key, Brush.solid(color, ink.alpha));
		}
		return brushes.get(key);
	}

	static function ink(value:Dynamic):Ink {
		var color:Dynamic = value.color == null ? "textPrimary" : value.color;
		if (Std.isOfType(color, String)) {
			if (!Lambda.exists(ColorToken.ALL, token -> Std.string(token) == color)) throw "Unknown canvas theme color";
		} else if (!Std.isOfType(color, Int) || color < 0 || color > 0xffffff) throw "Canvas color must be RGB or a theme token";
		return {color: color, alpha: number(value, "alpha", 1, 0, 1)};
	}

	public static function finite(value:Dynamic):Float {
		if ((!Std.isOfType(value, Int) && !Std.isOfType(value, Float)) || !Math.isFinite(value) || Math.abs(value) > 100000000)
			throw "Canvas coordinates must be finite numbers";
		return value;
	}

	public static function number(value:Dynamic, key:String, fallback = 0., min = -100000000., max = 100000000.):Float {
		var field = Reflect.field(value, key), result = field == null ? fallback : finite(field);
		if (result < min || result > max) throw 'Canvas $key is out of range';
		return result;
	}

	public static function text(value:Dynamic, key:String):String {
		var field = Reflect.field(value, key);
		if (!Std.isOfType(field, String)) throw 'Expected string $key';
		return field;
	}

	public static function list(value:Dynamic, key:String):Array<Dynamic> {
		var field = Reflect.field(value, key);
		if (field == null) return [];
		if (!Std.isOfType(field, Array) || (field : Array<Dynamic>).length > 50000) throw 'Invalid canvas $key list';
		return field;
	}

	static function box(value:Dynamic):{x:Float, y:Float, width:Float, height:Float}
		return {x: number(value, "x"), y: number(value, "y"), width: number(value, "width", 0, 0), height: number(value, "height", 0, 0)};
}
