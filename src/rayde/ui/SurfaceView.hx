package rayde.ui;

import ashui.layout.Element;
import ashui.reactive.Owner;
import ashui.types.PixelSurface;
import ashui.ui.Component;
import ashui.ui.Surface;
import rayde.preview.SurfacePump;
import rayde.preview.SurfaceProtocol;
import window.MouseButton;

typedef SurfaceViewProps = {
	pump:SurfacePump,
	source:PixelSurface,
	/** Called when the user presses Shift+Escape, the one key the app does not receive: where focus goes next is the caller's. */
	leave:Void->Void,
	/** Receives a function that reports this view's box in layout units, or null before it is laid out. */
	measure:Null<Void->Null<{width:Float, height:Float}>>->Void
};

/**
 * A headless app's picture, contained in its box, with the pointer, wheel, keys, text and focus forwarded to the app in its own pixels.
 * Keys that reach the app do not reach the workbench.
 */
class SurfaceView extends Component<SurfaceViewProps> {
	/** The point in the app's pixels under a position in this box, or null outside the picture. */
	public static function map(x:Float, y:Float, boxWidth:Float, boxHeight:Float, width:Int, height:Int):Null<{x:Int, y:Int}> {
		if (boxWidth <= 0 || boxHeight <= 0) return null;
		var scale = Math.min(boxWidth / width, boxHeight / height), left = (boxWidth - width * scale) / 2, top = (boxHeight - height * scale) / 2;
		var px = Math.floor((x - left) / scale), py = Math.floor((y - top) / scale);
		return {x: px < 0 ? 0 : px >= width ? width - 1 : px, y: py < 0 ? 0 : py >= height ? height - 1 : py};
	}

	static function button(b:Null<MouseButton>):Int
		return switch b {
			case null | Left: 0;
			case Right: 2;
			case Middle: 1;
			case Back: 3;
			case Forward: 4;
			case Other(n): n;
		};

	function render():Element {
		var pump = props.pump, source = props.source;
		var root:Element = null;
		props.measure(() -> {
			var box = root == null || root.tree == null ? null : root.tree.getBounds(root.node);
			return box == null ? null : {width: box.width, height: box.height};
		});
		// A view that goes away must not leave its measurement behind for the next one.
		Owner.onCleanup(() -> props.measure(null));
		function point(e:ashui.input.Events.PointerEvent):Null<{x:Int, y:Int}> {
			var box = root == null || root.tree == null ? null : root.tree.getBounds(root.node);
			return box == null ? null : map(e.localX, e.localY, box.width, box.height, source.width, source.height);
		}
		function pointer(type:Int):ashui.input.Events.PointerEvent->Void
			return e -> {
				var at = point(e);
				if (at == null) return;
				if (type == SurfaceProtocol.POINTER_DOWN) e.capturePointer();
				pump.send(type, at.x, at.y, button(e.button));
			};
		function flags(e:ashui.input.Events.KeyEvent):Int {
			var f = e.repeat ? SurfaceProtocol.REPEAT : 0;
			if (e.shift) f |= SurfaceProtocol.SHIFT;
			if (e.control) f |= SurfaceProtocol.CONTROL;
			if (e.alt) f |= SurfaceProtocol.ALT;
			if (e.superKey) f |= SurfaceProtocol.META;
			return f;
		}
		function code(e:ashui.input.Events.KeyEvent):Int
			return switch e.physicalKey {
				case Code(c): c;
				case Unidentified(_): -1;
			};
		function isLeave(e:ashui.input.Events.KeyEvent):Bool
			return e.shift && switch e.physicalKey {case Code(c): c == window.KeyCode.Escape; case _: false;};
		root = <div class="flex-1 min-h-0 min-w-0" focusable={true}
			onPointerDown={pointer(SurfaceProtocol.POINTER_DOWN)} onPointerUp={pointer(SurfaceProtocol.POINTER_UP)} onPointerMove={pointer(SurfaceProtocol.POINTER_MOVE)}
			onWheel={e -> {pump.send(SurfaceProtocol.WHEEL, Math.round(e.deltaX * 10), Math.round(e.deltaY * 10)); }}
			onKeyDown={e -> {
				if (isLeave(e)) {props.leave(); return;}
				e.preventDefault();
				pump.send(SurfaceProtocol.KEY_DOWN, code(e), 0, flags(e));
			}}
			onKeyUp={e -> {if (!isLeave(e)) pump.send(SurfaceProtocol.KEY_UP, code(e), 0, flags(e));}}
			onTextInput={e -> {for (i in 0...e.text.length) { var c = e.text.charCodeAt(i); if (c != null) pump.send(SurfaceProtocol.TEXT, c); }}}
			onFocus={_ -> pump.send(SurfaceProtocol.FOCUS, 1)} onBlur={_ -> pump.send(SurfaceProtocol.FOCUS, 0)}>
			<surface source={source} fit={ashui.types.ObjectFit.Contain} class="w-full h-full"/>
		</div>;
		return root;
	}
}
