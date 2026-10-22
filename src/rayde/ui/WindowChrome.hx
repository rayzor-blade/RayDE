package rayde.ui;

import ashui.animation.AnimationScheduler;
import ashui.reactive.Signal;

/** The window's controls as the title bar needs them: what the window is doing, and what to ask of it. */
class WindowChrome {
	public final maximized = Signal.make(false);
	public final fullscreen = Signal.make(false);

	/** Whether the window is the one in front. */
	public final focused = Signal.make(true);

	/** The actions asked of a window that is not there, newest last, for tests and offscreen renders. */
	public final calls:Array<String> = [];

	#if ashui_window
	final win:Null<window.Window>;

	public function new(?win:window.Window) {
		this.win = win;
		refresh();
	}

	/** The chrome of the running app's window; one with no window outside an app. */
	public static function ofApp():WindowChrome {
		var app = ashui.app.WindowedApp.current;
		return new WindowChrome(app == null ? null : app.window);
	}
	#else
	public function new() {}

	public static function ofApp():WindowChrome
		return new WindowChrome();
	#end

	/** Whether there is a window to act on. */
	public function real():Bool {
		#if ashui_window
		return win != null;
		#else
		return false;
		#end
	}

	public function title(value:String):Void {
		#if ashui_window
		if (win != null) win.setTitle(value);
		#end
	}

	/** Reads the window's state again. */
	public function refresh():Void {
		#if ashui_window
		if (win == null)
			return;
		maximized.set(win.isMaximized());
		fullscreen.set(win.isFullscreen());
		focused.set(win.hasFocus());
		#end
	}

	/** Reads the state now and as the window finishes changing it, which the system does after the request. */
	function settle():Void {
		refresh();
		for (after in [.15, .4, .8])
			AnimationScheduler.main.after(after, refresh);
	}

	public function minimize():Void {
		calls.push("minimize");
		#if ashui_window
		if (win != null)
			win.setMinimized(true);
		#end
	}

	public function toggleMaximize():Void {
		calls.push("maximize");
		#if ashui_window
		if (win != null) {
			win.setMaximized(!win.isMaximized());
			settle();
			return;
		}
		#end
		maximized.set(!maximized.get());
	}

	public function toggleFullscreen():Void {
		calls.push("fullscreen");
		#if ashui_window
		if (win != null) {
			win.setFullscreen(!win.isFullscreen());
			settle();
			return;
		}
		#end
		fullscreen.set(!fullscreen.get());
	}

	public function close():Void {
		calls.push("close");
		#if ashui_window
		if (win != null) {
			var app = ashui.app.WindowedApp.current;
			if (app != null)
				app.quit();
		}
		#end
	}

	/** Starts moving the window with the pointer, which must be down. */
	public function drag():Void {
		calls.push("drag");
		#if ashui_window
		if (win != null)
			win.dragWindow();
		#end
	}

	/** Starts resizing the window from an edge or a corner, `direction` being one of `East`, `North`, `NorthEast`... */
	public function resize(direction:String):Void {
		calls.push("resize " + direction);
		#if ashui_window
		if (win == null)
			return;
		var d:window.ResizeDirection = switch direction {
			case "North": North;
			case "South": South;
			case "East": East;
			case "West": West;
			case "NorthEast": NorthEast;
			case "NorthWest": NorthWest;
			case "SouthEast": SouthEast;
			case _: SouthWest;
		};
		win.dragResizeWindow(d);
		#end
	}

	/** Whether the edges can resize the window: not while it fills the screen. */
	public function resizable():Bool
		return !maximized.get() && !fullscreen.get();
}
