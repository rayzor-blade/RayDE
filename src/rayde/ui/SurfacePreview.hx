package rayde.ui;

import ashui.animation.AnimationScheduler;
import ashui.layout.Element;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.types.PixelSurface;
import ashui.ui.Component;
import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Spinner;
import ashui.components.DropdownMenu;
import rayde.preview.SurfacePump;

typedef SurfacePreviewProps = {pump:SurfacePump, title:String, leave:Void->Void, restart:Void->Void};

/** A headless app's picture in a tab: its title and state above the surface, which takes pointer and keys while focused. */
class SurfacePreview extends Component<SurfacePreviewProps> {
	/** The screen size the app is asked to draw at, kept while the app restarts: an aspect ratio, or "fit" for the tab's own. */
	public static final shape = Signal.make(startingShape());

	/** `RAYDE_SURFACE_SHAPE` (16:9, 4:3, 1:1, 9:16 or fit) starts the tab in that shape, for tests and screenshots. */
	static function startingShape():String {
		var value = Sys.getEnv("RAYDE_SURFACE_SHAPE");
		return value != null && ["16:9", "4:3", "1:1", "9:16", "fit"].indexOf(value) >= 0 ? value : "16:9";
	}

	/** Device pixels per layout unit of the window this tab is in. */
	public static function deviceScale():Float {
		#if ashui_window
		var app = ashui.app.WindowedApp.current;
		return app == null ? 1 : @:privateAccess app.scale();
		#else
		return 1;
		#end
	}

	function render():Element {
		var pump = props.pump, screen = Signal.make((null:Null<PixelSurface>)), state = Signal.make("starting"), timer:Null<ashui.animation.AnimationScheduler.Timer> = null, gone = false;
		// Pictures drawn and pictures received from the app each second, so a lag shows as a gap between the two or as a low first number.
		function chooseShape(value:String):Void shape.set(value);
		#if (ashui_window && !wasm)
		// A picture that changes every frame needs a frame of slack, or a late one waits out a whole refresh; the window goes back to its default after.
		var window = ashui.app.WindowedApp.current;
		if (window != null) window.frameLatency = 2;
		Owner.onCleanup(() -> if (window != null && !window.disposed) window.frameLatency = 1);
		#end
		function shapeItem(value:String, label:String):Element
			return <dropdown-menu-item id={"rayde-surface-shape-" + value.split(":").join("x")} onSelect={() -> chooseShape(value)}>
				<div class="flex items-center gap-2"><div class="size-4 shrink-0"><if {shape.get() == value}><icon document={Icons.CHECK_LINE} class="size-4"/></if></div><text>${label}</text></div>
			</dropdown-menu-item>;
		// What the app wrote to stderr, the last lines of it: all there is to say when it never drew or ended.
		var log:Array<String> = [], lines = Signal.make(([]:Array<String>));
		var rate = Signal.make(""), shown = 0, ticks = 0, grants = 0, received = pump.feed.frames, since = haxe.Timer.stamp(), due = since, grantAt = since, measure:Null<Void->Null<{width:Float, height:Float}>> = null, checkAt = since, wanted = "", steady = 0, asked = "";
		// Ticks come twice as fast as the app's frames, so each picture is taken within a few milliseconds of arriving instead of waiting for a tick that drifts against the app's clock.
		// Each tick is due a fixed step after the last one was due, so slow ticks do not push every later one back.
		function step():Bool {
			if (gone) return false;
			var now = haxe.Timer.stamp();
			ticks++;
			if (now - since >= 1) {
				var got = pump.feed.frames;
				rate.set(Math.round(shown / (now - since)) + " fps shown · " + Math.round((got - received) / (now - since)) + "/s from the app · tick " + Math.round((now - since) / ticks * 1000) + " ms · " + Math.round(grants / (now - since)) + " credits/s, " + pump.outstanding() + " out · " + (ticks - shown) + " ticks without a new picture");
				shown = 0; ticks = 0; grants = 0; received = got; since = now;
			}
			var made = screen.get(), size = pump.size();
			if (made == null && pump.ready()) {
				// The app announced a size: the picture needs a surface of that size.
				pump.invalidate();
				screen.set(new PixelSurface(size.width, size.height));
				state.set("running");
			} else if (made != null && size.width > 0 && (made.width != size.width || made.height != size.height)) {
				// The app resized. The view draws the surface it was made with, so it goes away for a tick and comes back with the new one.
				screen.set(null);
			}
			if (now >= checkAt && measure != null && screen.get() != null) {
				checkAt = now + .2;
				var box = measure(), scale = deviceScale();
				if (box != null && box.width > 8 && box.height > 8) {
					// Draw at the tab's own pixels, so the picture is not resampled. A size that holds for three looks is a resize that has finished.
					var boxW = box.width * scale, boxH = box.height * scale;
					var ratio = switch shape.get() {case "16:9": 16 / 9; case "4:3": 4 / 3; case "1:1": 1.; case "9:16": 9 / 16; case _: boxW / boxH;};
					// The largest picture of that shape that fits the tab; the view centres it.
					var fitW = boxW / boxH > ratio ? boxH * ratio : boxW, fitH = boxW / boxH > ratio ? boxH : boxW / ratio;
					var w = Std.int(Math.max(64, Math.min(4096, Math.round(fitW)))), h = Std.int(Math.max(64, Math.min(4096, Math.round(fitH)))), key = w + "x" + h;
					steady = key == wanted ? steady + 1 : 0;
					wanted = key;
					if (steady >= 2 && key != asked && (w != size.width || h != size.height)) {
						asked = key;
						pump.resize(w, h);
					}
				}
			}
			// One credit every 1/60 s: the app draws when asked, so its frames arrive in step with this clock.
			if (now >= grantAt) {
				grantAt = Math.max(grantAt + 1 / 60, now);
				if (pump.grant()) grants++;
			}
			var surface = screen.get();
			if (surface != null && pump.poll(surface)) shown++;
			var written = [for (line in pump.takeLog()) if (line.indexOf("[ash]") != 0 && line.indexOf("[promote]") != 0 && line.indexOf(" : Warning : ") < 0) line];
			if (written.length > 0) { log = log.concat(written).slice(-200); lines.set(log.slice(-14)); }
			if (pump.finished()) { state.set(pump.failure != null ? "stopped: " + pump.failure : "exited"); return false; }
			due = Math.max(due + 1 / 120, now);
			return true;
		}
		// A failure in one tick shows in the header and does not end the ticks: the picture would freeze with nothing to say why.
		function tick():Void {
			var again = true;
			try again = step() catch (e:Dynamic) rate.set("viewer error: " + e);
			if (again && !gone) timer = AnimationScheduler.main.after(Math.max(.001, due - haxe.Timer.stamp()), tick);
		}
		timer = AnimationScheduler.main.after(.016, tick);
		Owner.onCleanup(() -> {gone = true; if (timer != null) timer.cancel();});
		return <div id="rayde-surface-preview" class="flex flex-col flex-1 min-h-0 min-w-0">
			<div class="flex items-center justify-between gap-3 p-2 border-b border-border shrink-0">
				<div class="flex items-center gap-2 min-w-0 flex-1"><if {state.get() == "starting"}><spinner size={Sm}/></if><text class="text-sm text-text-secondary min-w-0 truncate">${props.title + " · " + state.get() + (rate.get() == "" ? "" : " · " + rate.get())}</text></div>
				<dropdown-menu id="rayde-surface-shape-menu">
					<dropdown-menu-trigger id="rayde-surface-shape" variant={Ghost} size={Sm} class="shrink-0"><icon document={Icons.ASPECT_RATIO_LINE} class="size-4"/><text class="text-sm">${shape.get() == "fit" ? "Fit" : shape.get()}</text></dropdown-menu-trigger>
					<dropdown-menu-content>
						<dropdown-menu-label>Screen size</dropdown-menu-label>
						<dropdown-menu-separator/>
						${shapeItem("16:9", "16:9  Widescreen")}
						${shapeItem("4:3", "4:3  Standard")}
						${shapeItem("1:1", "1:1  Square")}
						${shapeItem("9:16", "9:16  Portrait")}
						${shapeItem("fit", "Fit to the tab")}
					</dropdown-menu-content>
				</dropdown-menu>
				<button id="rayde-surface-restart" variant={Ghost} class="shrink-0" size={Sm} onClick={_ -> props.restart()}><icon document={Icons.RESTART_LINE} class="size-4"/>Restart</button>
			</div>
			<if {(screen.get() == null || state.get() != "running") && lines.get().length > 0}><div id="rayde-surface-log" class="flex flex-col gap-1 p-3 overflow-auto shrink-0"><for {line in lines}><text class="text-xs text-text-secondary">${line}</text></for></div></if>
			<if {screen.get() != null}><surface-view pump={pump} source={screen.get()} leave={props.leave} measure={m -> measure = m}/></if>
		</div>;
	}
}
