package rayde.ui;

import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.ui.Component;
import ashui.ui.Div;
import ashui.ui.Ref;
import rayde.ext.Studio;

typedef StudioViewProps = {studio:Studio, onMocks:Void->Void};

/**
 * The Preview of an extension: what its view looks like now, in a card of its own, with the controls
 * that matter while writing it: reload, and whether typing reloads. The nodes belong to the Studio and
 * are only placed here, so this page can be built again around them.
 */
class StudioView extends Component<StudioViewProps> {
	function render():Element {
		var studio = props.studio, surface = new Ref<Div>();
		var view = <div id="rayde-studio" class="rayde-card flex flex-col flex-1 min-h-0 min-w-0">
			<div class="rayde-studio-bar flex items-center gap-2 px-3 shrink-0" height={40}>
				<icon document={Icons.PUZZLE_LINE} class="size-4 shrink-0 text-text-secondary"/>
				<text class="text-sm font-medium">Preview</text>
				<text id="rayde-studio-state" class="text-xs text-text-tertiary flex-1 min-w-0">${label(studio.state.get())}</text>
				<tooltip label="Typing reloads the extension" side="bottom">
					<button id="rayde-studio-live" variant={Ghost} size={Sm} class="rayde-studio-live" onClick={_ -> studio.live.set(!studio.live.get())}>
						<icon document={Icons.FLASHLIGHT_LINE} class="size-4"/>
						<text class="text-xs">${studio.live.get() ? "Live" : "On save"}</text>
					</button>
				</tooltip>
				<tooltip label="Mocked answers for remote modules" side="bottom">
					<button id="rayde-studio-mocks" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> props.onMocks()}><icon document={Icons.BRACES_LINE} class="size-4"/></button>
				</tooltip>
				<tooltip label="Reload the extension" side="bottom">
					<button id="rayde-studio-reload" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> studio.reload()}><icon document={Icons.REFRESH_LINE} class="size-4"/></button>
				</tooltip>
			</div>
			<div ref={surface} id="rayde-studio-surface" class="rayde-studio-surface flex flex-col flex-1 min-h-0 overflow-auto"/>
		</div>;
		var node = surface.get().node;
		studio.attach(node);
		ashui.reactive.Owner.onCleanup(() -> studio.detach(node));
		return view;
	}

	static function label(state:String):String
		return switch state {
			case "running": "Running";
			case "exited": "The extension stopped";
			case "unavailable": "rayscript-host was not found";
			case _: "Not running";
		}
}
