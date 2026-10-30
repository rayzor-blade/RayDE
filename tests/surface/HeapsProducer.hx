import rayde.surface.HeapsSurface;

/** A small Heaps scene shown in RayDE's Surface Preview: moving ball, a label and a marker where the pointer is pressed. Arguments: width height frames. */
class HeapsProducer extends hxd.App {
	static var width = 640;
	static var height = 360;
	static var frames = 0;

	var ball:h2d.Graphics;
	var time = 0.;
	var shown = 0;
	var link:rayde.preview.SurfaceLink;

	override function init() {
		engine.backgroundColor = 0xFF20242C;
		var label = new h2d.Text(hxd.res.DefaultFont.get(), s2d);
		label.text = "Heaps through the surface protocol";
		label.x = 24;
		label.y = 24;
		label.scale(2);
		ball = new h2d.Graphics(s2d);
		ball.beginFill(0x4C8BF5);
		ball.drawCircle(0, 0, 40);
		ball.endFill();
		var markers = new h2d.Object(s2d);
		var pad = new h2d.Interactive(width, height, s2d);
		pad.onPush = e -> {
			var m = new h2d.Graphics(markers);
			m.beginFill(0xFF5A3C);
			m.drawCircle(e.relX, e.relY, 8);
			m.endFill();
		};
		link = HeapsSurface.attach(this, width, height);
	}

	override function update(dt:Float) {
		time += dt;
		ball.x = width / 2 + Math.cos(time * 2) * (width / 3);
		ball.y = height / 2 + Math.sin(time * 3) * (height / 4);
		if (frames > 0 && ++shown == frames) link.finish();
	}

	static function main() {
		var args = Sys.args();
		if (args.length > 0) width = Std.parseInt(args[0]);
		if (args.length > 1) height = Std.parseInt(args[1]);
		if (args.length > 2) frames = Std.parseInt(args[2]);
		new HeapsProducer();
	}
}
