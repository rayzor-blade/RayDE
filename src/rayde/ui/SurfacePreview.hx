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
import rayde.preview.SurfacePump;

typedef SurfacePreviewProps = {pump:SurfacePump, title:String, leave:Void->Void, restart:Void->Void};

/** A headless app's picture in a tab: its title and state above the surface, which takes pointer and keys while focused. */
class SurfacePreview extends Component<SurfacePreviewProps> {
	function render():Element {
		var pump = props.pump, screen = Signal.make((null:Null<PixelSurface>)), state = Signal.make("starting"), timer:Null<ashui.animation.AnimationScheduler.Timer> = null, gone = false;
		// Pictures drawn and pictures received from the app each second, so a lag shows as a gap between the two or as a low first number.
		var rate = Signal.make(""), shown = 0, ticks = 0, grants = 0, received = pump.feed.frames, since = haxe.Timer.stamp(), due = since, grantAt = since;
		// Ticks come twice as fast as the app's frames, so each picture is taken within a few milliseconds of arriving instead of waiting for a tick that drifts against the app's clock.
		// Each tick is due a fixed step after the last one was due, so slow ticks do not push every later one back.
		function tick():Void {
			if (gone) return;
			var now = haxe.Timer.stamp();
			ticks++;
			if (now - since >= 1) {
				var got = pump.feed.frames;
				rate.set(Math.round(shown / (now - since)) + " fps shown · " + Math.round((got - received) / (now - since)) + "/s from the app · tick " + Math.round((now - since) / ticks * 1000) + " ms · " + Math.round(grants / (now - since)) + " credits/s, " + pump.outstanding() + " out · " + (ticks - shown) + " ticks without a new picture");
				shown = 0; ticks = 0; grants = 0; received = got; since = now;
			}
			if (screen.get() == null && pump.ready()) {
				var size = pump.size();
				pump.invalidate();
				screen.set(new PixelSurface(size.width, size.height));
				state.set("running");
			}
			// One credit every 1/60 s: the app draws when asked, so its frames arrive in step with this clock.
			if (now >= grantAt) {
				grantAt = Math.max(grantAt + 1 / 60, now);
				if (pump.grant()) grants++;
			}
			var surface = screen.get();
			if (surface != null && pump.poll(surface)) shown++;
			if (pump.finished()) { state.set(pump.failure != null ? "stopped: " + pump.failure : "exited"); return; }
			due = Math.max(due + 1 / 120, now);
			timer = AnimationScheduler.main.after(Math.max(.001, due - haxe.Timer.stamp()), tick);
		}
		timer = AnimationScheduler.main.after(.016, tick);
		Owner.onCleanup(() -> {gone = true; if (timer != null) timer.cancel();});
		return <div id="rayde-surface-preview" class="flex flex-col flex-1 min-h-0 min-w-0">
			<div class="flex items-center justify-between gap-3 p-2 border-b border-border shrink-0">
				<div class="flex items-center gap-2 min-w-0"><if {state.get() == "starting"}><spinner size={Sm}/></if><text class="text-sm text-text-secondary">${props.title + " · " + state.get() + (rate.get() == "" ? "" : " · " + rate.get())}</text></div>
				<button id="rayde-surface-restart" variant={Ghost} size={Sm} onClick={_ -> props.restart()}><icon document={Icons.RESTART_LINE} class="size-4"/>Restart</button>
			</div>
			<if {screen.get() != null}><surface-view pump={pump} source={screen.get()} leave={props.leave}/></if>
		</div>;
	}
}
