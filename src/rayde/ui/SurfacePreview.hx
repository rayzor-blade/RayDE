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
		function tick():Void {
			if (gone) return;
			if (screen.get() == null && pump.ready()) {
				var size = pump.size();
				pump.invalidate();
				screen.set(new PixelSurface(size.width, size.height));
				state.set("running");
			}
			var surface = screen.get();
			if (surface != null) pump.poll(surface);
			if (pump.finished()) state.set(pump.failure != null ? "stopped: " + pump.failure : "exited");
			else timer = AnimationScheduler.main.after(.016, tick);
		}
		timer = AnimationScheduler.main.after(.016, tick);
		Owner.onCleanup(() -> {gone = true; if (timer != null) timer.cancel();});
		return <div id="rayde-surface-preview" class="flex flex-col flex-1 min-h-0 min-w-0">
			<div class="flex items-center justify-between gap-3 p-2 border-b border-border shrink-0">
				<div class="flex items-center gap-2 min-w-0"><if {state.get() == "starting"}><spinner size={Sm}/></if><text class="text-sm text-text-secondary">${props.title + " · " + state.get()}</text></div>
				<button id="rayde-surface-restart" variant={Ghost} size={Sm} onClick={_ -> props.restart()}><icon document={Icons.RESTART_LINE} class="size-4"/>Restart</button>
			</div>
			<if {screen.get() != null}><surface-view pump={pump} source={screen.get()} leave={props.leave}/></if>
		</div>;
	}
}
