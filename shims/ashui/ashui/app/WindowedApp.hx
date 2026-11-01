package ashui.app;

import ashui.core.render.Offscreen;
import ashui.css.Css;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.theme.ColorScheme;
import ashui.theme.ThemeState;
import ashui.theme.themes.DefaultTheme;
import gpu.GpuTexture;
import gpu.GpuTextureView;
import gpu.GpuTextureViewDescriptor;
import rayde.preview.SurfaceLink;
import rayde.preview.SurfaceProtocol;
import window.Key;
import window.KeyCode;
import window.KeyEvent;
import window.Modifiers;
import window.MouseButton;
import window.MouseElementState;
import window.NamedKey;

/**
 * Stands in for `WindowedApp` in a surface build: `run` draws the app offscreen and streams each frame to RayDE's Surface Preview, with the
 * viewer's pointer, wheel and typed text delivered to the tree. The app's source is unchanged; the surface build puts this class ahead of ashui's.
 * The size is RAYDE_SURFACE_SIZE (WIDTHxHEIGHT) or the window config's, and follows the viewer's resizes. Editing, arrow and navigation keys, letters and digits are delivered as key events; other keys are ignored.
 */
class WindowedApp {
	static inline var FRAME_SECONDS = 1 / 60;

	public static function run(settings:WindowConfig, build:Void->Element):Int {
		SurfaceLink.redirectTrace();
		var config:WindowConfig.WindowConfigData = settings;
		var size = (Sys.getEnv("RAYDE_SURFACE_SIZE") ?? "").split("x");
		var width = size.length == 2 ? Std.parseInt(size[0]) : config.width ?? 800;
		var height = size.length == 2 ? Std.parseInt(size[1]) : config.height ?? 600;
		// There is no window to ask for the system's scheme, so the theme starts dark.
		if (config.theme != null || ThemeState.tryGet() == null) ThemeState.init(config.theme != null ? config.theme : DefaultTheme.bundle(), ColorScheme.Dark);
		var tree = new LayoutTree();
		var root:Element = Owner.root(tree, _ -> build());
		var offscreen = Offscreen.create();
		var background = ThemeState.get().color(Background);
		offscreen.clear = background.rgb();
		offscreen.clearAlpha = background.a;
		var link = new SurfaceLink(width, height);
		link.start();
		var texture:Null<GpuTexture> = null, view:Null<GpuTextureView> = null;
		var last = haxe.Timer.stamp(), next = 0.;
		while (!link.viewerGone) {
			var wanted = link.takeResize();
			if (wanted != null) {
				width = wanted.width;
				height = wanted.height;
				link.resize(width, height);
				if (view != null) view.destroy();
				if (texture != null) texture.destroy();
				texture = null;
				view = null;
			}
			deliver(tree, link);
			if (link.viewerPaces) {
				// The viewer is the clock: a frame starts when it grants one.
				if (!link.takeCredit(.1)) continue;
			} else {
				var now = haxe.Timer.stamp();
				if (next > now) Sys.sleep(next - now);
				next = Math.max(next, now) + FRAME_SECONDS;
			}
			var now = haxe.Timer.stamp();
			Offscreen.advance(Math.min(now - last, .1));
			last = now;
			Css.setViewport(width, height);
			Css.update();
			tree.flush();
			tree.computeLayout(root.node, width, height);
			if (texture == null) {
				texture = offscreen.createTexture(width, height);
				view = texture.createView(new GpuTextureViewDescriptor());
			}
			offscreen.renderTree(tree, root.node, view, width, height);
			var pixels = offscreen.readRgba8(texture, width, height);
			var picture = link.buffer();
			picture.blit(0, pixels, 0, pixels.length);
			link.submit(picture);
		}
		return 0;
	}

	static function deliver(tree:LayoutTree, link:SurfaceLink):Void {
		for (input in link.takeInputs()) switch input.type {
			case SurfaceProtocol.POINTER_MOVE:
				ashui.input.Pointer.move(tree, input.a, input.b);
			case SurfaceProtocol.POINTER_DOWN:
				ashui.input.Pointer.move(tree, input.a, input.b);
				ashui.input.Pointer.press(tree, button(input.c));
			case SurfaceProtocol.POINTER_UP:
				ashui.input.Pointer.move(tree, input.a, input.b);
				ashui.input.Pointer.release(tree, button(input.c));
			case SurfaceProtocol.WHEEL:
				// Deltas arrive in tenths of a pixel.
				ashui.input.Pointer.wheel(tree, input.a / 10, input.b / 10);
			case SurfaceProtocol.TEXT:
				ashui.input.Keyboard.text(tree, String.fromCharCode(input.a));
			case SurfaceProtocol.KEY_DOWN | SurfaceProtocol.KEY_UP:
				var shift = (input.c & SurfaceProtocol.SHIFT) != 0;
				var logical = logicalKey(input.a, shift);
				if (logical == null) continue;
				var state = input.type == SurfaceProtocol.KEY_DOWN ? MouseElementState.Pressed : MouseElementState.Released;
				var modifiers = Modifiers.State(shift, (input.c & SurfaceProtocol.CONTROL) != 0, (input.c & SurfaceProtocol.ALT) != 0, (input.c & SurfaceProtocol.META) != 0, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown, Unknown);
				ashui.input.Keyboard.input(tree, KeyEvent.Input(Code(input.a), logical, None, Standard, state, (input.c & SurfaceProtocol.REPEAT) != 0, Unavailable), modifiers);
			case _:
		}
	}

	/** The key a physical key code stands for, for the keys an app acts on; null for the rest. */
	static function logicalKey(code:Int, shift:Bool):Null<Key> {
		var named:Null<NamedKey> = switch (code : KeyCode) {
			case Enter | NumpadEnter: Enter;
			case Tab: Tab;
			case Backspace: Backspace;
			case Delete: Delete;
			case Escape: Escape;
			case Space: Space;
			case ArrowLeft: ArrowLeft;
			case ArrowRight: ArrowRight;
			case ArrowUp: ArrowUp;
			case ArrowDown: ArrowDown;
			case Home: Home;
			case End: End;
			case PageUp: PageUp;
			case PageDown: PageDown;
			case _: null;
		};
		if (named != null) return Named(named);
		var letterA:Int = KeyCode.KeyA, letterZ:Int = KeyCode.KeyZ, digit0:Int = KeyCode.Digit0, digit9:Int = KeyCode.Digit9;
		if (code >= letterA && code <= letterZ) {
			var letter = String.fromCharCode(97 + code - letterA);
			return Character(shift ? letter.toUpperCase() : letter);
		}
		if (code >= digit0 && code <= digit9) return Character(String.fromCharCode(48 + code - digit0));
		return null;
	}

	static function button(code:Int):MouseButton
		return switch code {
			case 0: Left;
			case 1: Middle;
			case 2: Right;
			case 3: Back;
			case 4: Forward;
			case n: Other(n);
		};
}
