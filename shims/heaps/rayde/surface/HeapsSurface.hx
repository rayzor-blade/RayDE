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
	var target:h3d.mat.Texture;
	final stats = Sys.getEnv("SURFACE_STATS") == "1";
	var drawTime = 0.;
	var readTime = 0.;
	var captured = 0;

	function new(app:hxd.App, link:SurfaceLink) {
		this.app = app;
		this.link = link;
		target = new h3d.mat.Texture(link.width, link.height, [Target]);
		frameSeconds = 1 / fps;
	}

	/** Starts streaming `app`'s scene at `width` by `height`. Returns the link, for its `deflate` option. Call from `init`. */
	public static function attach(app:hxd.App, width:Int, height:Int):SurfaceLink {
		var surface = create(app, width, height);
		// Heaps installs its own loop after `init` returns, and runs one frame itself first, so the wrapper goes in on the second frame.
		var loop = @:privateAccess app.mainLoop;
		new Install(app.s2d, () -> hxd.System.setLoop(() -> {
			surface.deliver();
			loop();
			surface.captureOrExit();
		}));
		return surface.link;
	}

	static var current:Null<HeapsSurface>;

	/**
	 * Called by the injected build step before each frame of any `hxd.App`; the frame runs only when this returns true. The first call starts
	 * streaming at RAYDE_SURFACE_SIZE (WIDTHxHEIGHT, default 800x600). Once the viewer sends credits, a frame starts when one is held.
	 */
	public static function before(app:hxd.App):Bool {
		if (current == null) {
			var size = (Sys.getEnv("RAYDE_SURFACE_SIZE") ?? "800x600").split("x"), width = Std.parseInt(size[0]), height = Std.parseInt(size[1]);
			current = create(app, width ?? 800, height ?? 600, true);
		}
		current.deliver();
		var wanted = current.link.takeResize();
		if (wanted != null) current.resizeTo(wanted.width, wanted.height);
		if (!current.link.viewerPaces) return true;
		// The raw time between frames is the viewer's own interval between credits, which follows its display, so motion stays true to display time.
		// A short wait keeps the app answering its window and noticing a viewer that left.
		return current.link.takeCredit(.1);
	}

	/** Called after each frame: draws the scene to the texture and sends what changed, then waits out the rest of the frame (RAYDE_SURFACE_FPS, default 60) so the app does not outrun the viewer. */
	public static function after(app:hxd.App):Void {
		if (current == null) return;
		current.captureOrExit();
		if (!current.link.viewerPaces) current.pace();
	}

	/** `fit` keeps the scene at the size the app laid itself out for and scales it, centred, to the picture; without it the scene is `width` by `height` as is. */
	static function create(app:hxd.App, width:Int, height:Int, fit = false):HeapsSurface {
		SurfaceLink.redirectTrace();
		var window = hxd.Window.getInstance();
		var design = fit ? {width: app.s2d.width, height: app.s2d.height} : null;
		window.resize(width, height);
		// The window's own resize event arrives later; the scene scales and aligns by the engine's size, which has to be right now.
		app.engine.resize(width, height);
		// The picture is read back from a texture, so the app needs no visible window.
		if (Sys.getEnv("SURFACE_SHOW_WINDOW") != "1") @:privateAccess window.window.visible = false;
		var link = new SurfaceLink(width, height), surface = new HeapsSurface(app, link);
		surface.design = design;
		surface.fitScene(width, height);
		link.start();
		return surface;
	}

	var design:Null<{width:Int, height:Int}>;

	/** How the design-sized scene sits in the picture: its scale and where its top-left lands. `Scene.drawTo` ignores the scene's scale mode, so the transform is the scene's own. */
	var zoom = 1.;
	var offsetX = 0.;
	var offsetY = 0.;

	function fitScene(width:Int, height:Int):Void {
		if (design == null) {
			app.s2d.scaleMode = Fixed(width, height, 1);
			return;
		}
		// The scene stays the size the app laid itself out for, so its coordinates mean what the app expects; the picture shows it scaled to fit, centred.
		app.s2d.scaleMode = Fixed(design.width, design.height, 1, Left, Top);
		zoom = Math.min(width / design.width, height / design.height);
		offsetX = (width - design.width * zoom) / 2;
		offsetY = (height - design.height * zoom) / 2;
		app.s2d.setScale(zoom);
		app.s2d.setPosition(offsetX, offsetY);
	}

	/** Draws at a new size: the window and the scene's stage follow, the render target is replaced, and the link announces it with the next picture. */
	function resizeTo(width:Int, height:Int):Void {
		if (width == link.width && height == link.height) return;
		hxd.Window.getInstance().resize(width, height);
		app.engine.resize(width, height);
		fitScene(width, height);
		target.dispose();
		target = new h3d.mat.Texture(width, height, [Target]);
		link.resize(width, height);
	}

	var nextFrameAt = 0.;
	final fps = Math.max(1, Std.parseFloat(Sys.getEnv("RAYDE_SURFACE_FPS") ?? "60"));
	final frameSeconds:Float;

	function pace():Void {
		var now = haxe.Timer.stamp();
		nextFrameAt = nextFrameAt == 0 ? now + frameSeconds : nextFrameAt + frameSeconds;
		// A frame that ran long does not make the next ones catch up in a burst.
		if (nextFrameAt < now) nextFrameAt = now;
		else Sys.sleep(nextFrameAt - now);
	}

	function captureOrExit():Void {
		try capture() catch (e:Dynamic) {
			Sys.stderr().writeString('surface capture failed: $e\n${haxe.CallStack.toString(haxe.CallStack.exceptionStack())}\n');
			Sys.exit(1);
		}
	}

	function deliver():Void {
		// Ending from the render thread: the sender thread's own exit does not stop a Heaps app.
		if (link.viewerGone) Sys.exit(0);
		var window = hxd.Window.getInstance();
		for (input in link.takeInputs()) {
			var kind:Null<EventKind> = switch input.type {
				case SurfaceProtocol.POINTER_DOWN: EventKind.EPush;
				case SurfaceProtocol.POINTER_UP: EventKind.ERelease;
				case SurfaceProtocol.POINTER_MOVE: EventKind.EMove;
				case _: null;
			};
			if (kind == null) continue;
			// Pointer positions arrive in the picture's pixels; the scene's own are the design's.
			var e = new hxd.Event(kind, (input.a - offsetX) / zoom, (input.b - offsetY) / zoom);
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
