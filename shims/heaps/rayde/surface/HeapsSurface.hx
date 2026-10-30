package rayde.surface;

import haxe.io.Bytes;
import rayde.preview.SurfaceLink;
import hxd.Event.EventKind;
import rayde.preview.SurfaceProtocol;

/**
 * Presents a Heaps app in RayDE's Surface Preview. Call `HeapsSurface.attach(this, 800, 600)` from `init`: after each frame the scene is drawn
 * to a texture, read back and streamed, and the viewer's pointer, wheel and key input is delivered to the app as Heaps events.
 */
class HeapsSurface {
	final link:SurfaceLink;
	final app:hxd.App;
	final target:h3d.mat.Texture;
	final stats = Sys.getEnv("SURFACE_STATS") == "1";
	var drawTime = 0.;
	var readTime = 0.;
	var captured = 0;

	function new(app:hxd.App, link:SurfaceLink) {
		this.app = app;
		this.link = link;
		target = new h3d.mat.Texture(link.width, link.height, [Target]);
	}

	/** Starts streaming `app`'s scene at `width` by `height`. Returns the link, for its `deflate` option. */
	public static function attach(app:hxd.App, width:Int, height:Int):SurfaceLink {
		SurfaceLink.redirectTrace();
		hxd.Window.getInstance().resize(width, height);
		app.s2d.scaleMode = Fixed(width, height, 1);
		var link = new SurfaceLink(width, height), surface = new HeapsSurface(app, link);
		link.start();
		// Heaps installs its own loop after `init` returns, and runs one frame itself first, so the wrapper goes in on the second frame.
		var loop = @:privateAccess app.mainLoop;
		new Install(app.s2d, () -> hxd.System.setLoop(() -> {
			surface.deliver();
			loop();
			try surface.capture() catch (e:Dynamic) {
				Sys.stderr().writeString('surface capture failed: $e\n${haxe.CallStack.toString(haxe.CallStack.exceptionStack())}\n');
				Sys.exit(1);
			}
		}));
		return link;
	}

	function deliver():Void {
		var window = hxd.Window.getInstance();
		for (input in link.takeInputs()) {
			var kind:Null<EventKind> = switch input.type {
				case SurfaceProtocol.POINTER_DOWN: EventKind.EPush;
				case SurfaceProtocol.POINTER_UP: EventKind.ERelease;
				case SurfaceProtocol.POINTER_MOVE: EventKind.EMove;
				case _: null;
			};
			if (kind == null) continue;
			var e = new hxd.Event(kind, input.a, input.b);
			e.button = input.c;
			window.event(e);
		}
	}

	function capture():Void {
		var t0 = haxe.Timer.stamp();
		target.clear(app.engine.backgroundColor & 0xFFFFFF, 1);
		app.s2d.drawTo(target);
		var t1 = haxe.Timer.stamp();
		var pixels = new hxd.Pixels(link.width, link.height, link.buffer(), RGBA);
		// Reads into a pooled buffer, as Texture.capturePixels does but without allocating a picture each frame.
		var driver = app.engine.driver;
		driver.setRenderTarget(target);
		driver.captureRenderBuffer(pixels);
		driver.setRenderTarget(null);
		link.submit(pixels.bytes);
		if (!stats) return;
		drawTime += t1 - t0;
		readTime += haxe.Timer.stamp() - t1;
		if (++captured % 60 == 0)
			Sys.stderr().writeString('stats: per frame ms draw to texture ${Math.round(drawTime / captured * 10000) / 10} readback ${Math.round(readTime / captured * 10000) / 10}\n');
	}
}

/** Runs `install` during the second frame's sync, then removes itself. */
private class Install extends h2d.Object {
	final install:Void->Void;
	var frames = 0;

	public function new(parent:h2d.Object, install:Void->Void) {
		super(parent);
		this.install = install;
	}

	override function sync(ctx:h2d.RenderContext) {
		super.sync(ctx);
		if (++frames < 2) return;
		install();
		remove();
	}
}
