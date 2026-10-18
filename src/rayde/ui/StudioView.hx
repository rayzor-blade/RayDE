package rayde.ui;

import ashui.components.Button;
import ashui.components.DropdownMenu;
import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.ui.Component;
import ashui.ui.Div;
import ashui.ui.Ref;
import rayde.ext.Manifest.ViewTool;
import rayde.ext.Studio;

typedef StudioViewProps = {
	studio:Studio,
	onMocks:Void->Void,
	onConsole:Void->Void,
	/** Whether it is a card of its own, as in a tab or beside the code; false where the part of the layout it is in has its own. */
	?framed:Bool
};

/**
 * The view of an extension where it is shown: its header, which the extension configures (a title it can change, and
 * the tools its config lists), and under it the view. Beside the tools is a menu of what matters while writing the
 * extension: reload, whether typing reloads, the mocked answers, the console, and how it is running. The nodes of the
 * view belong to the Studio and are only placed here, so what is around them can be built again.
 */
class StudioView extends Component<StudioViewProps> {
	function render():Element {
		var studio = props.studio, surface = new Ref<Div>();
		var body = <div class="flex flex-col flex-1 min-h-0 min-w-0">
			<div id="rayde-studio-bar" class="rayde-studio-bar flex items-center gap-1 pl-3 pr-2 shrink-0" height={36}>
				<text id="rayde-studio-title" class="rayde-heading flex-1 min-w-0 truncate">${studio.title.get()}</text>
				{[for (t in studio.tools()) tool(t)]}
				<for {k in [{state: studio.state.get(), stale: studio.stale.get(), live: studio.live.get()}]}>${menu(k.state, k.stale, k.live)}</for>
			</div>
			<for {stale in [studio.stale.get()]}>${banner(stale)}</for>
			<div ref={surface} id="rayde-studio-surface" class="rayde-studio-surface flex flex-col flex-1 min-h-0 overflow-auto"/>
		</div>;
		var node = surface.get().node;
		studio.attach(node);
		ashui.reactive.Owner.onCleanup(() -> studio.detach(node));
		if (props.framed == false)
			return <div id="rayde-studio" class="flex flex-col flex-1 min-h-0 min-w-0">{body}</div>;
		return <div id="rayde-studio" class="rayde-card flex flex-col flex-1 min-h-0 min-w-0">{body}</div>;
	}

	/** One of the tools the extension's config puts in its header. */
	function tool(t:ViewTool):Element {
		var icon = props.studio.manifest == null ? Icons.APPS_LINE : ViewIcons.tool(props.studio.manifest, t);
		return <tooltip label={t.title} side="bottom">
			<button id={"rayde-tool-" + t.id} variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> props.studio.tool(t.id)}><icon document={icon} class="size-4"/></button>
		</tooltip>;
	}

	/** How the extension is running, and the controls for writing it. */
	function menu(state:String, stale:Bool, live:Bool):Element {
		var studio = props.studio;
		return <div class="flex items-center gap-1 shrink-0">
			<tooltip label={label(state, stale)} side="bottom">${dot(state, stale)}</tooltip>
			<dropdown-menu id="rayde-studio-menu">
				<dropdown-menu-trigger id="rayde-studio-more" variant={Ghost} size={Icon} class="rayde-panel-button rayde-studio-more"><icon document={Icons.MORE_LINE} class="size-4"/></dropdown-menu-trigger>
				<dropdown-menu-content>
					<dropdown-menu-label>${label(state, stale)}</dropdown-menu-label>
					<dropdown-menu-separator/>
					<dropdown-menu-item id="rayde-menu-reload" onSelect={() -> studio.reload()}>Reload extension</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-live" onSelect={() -> studio.live.set(!studio.live.get())}>${live ? "Turn off reloading as you type" : "Reload as you type"}</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-mocks" onSelect={() -> props.onMocks()}>Edit mocked answers…</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-console" onSelect={() -> props.onConsole()}>Show extension console</dropdown-menu-item>
				</dropdown-menu-content>
			</dropdown-menu>
		</div>;
	}

	/** A small light for how it is going: green running, amber showing an older version, red stopped, grey not running. */
	function dot(state:String, stale:Bool):Element {
		if (stale)
			return <div class="rayde-dot size-2 rounded-full bg-warning"/>;
		return switch state {
			case "running": <div class="rayde-dot size-2 rounded-full bg-success"/>;
			case "exited" | "unavailable": <div class="rayde-dot size-2 rounded-full bg-error"/>;
			case _: <div class="rayde-dot size-2 rounded-full bg-text-tertiary"/>;
		}
	}

	/** Said under the header while the view shown is not the one the source describes. */
	function banner(stale:Bool):Element {
		if (!stale)
			return <div/>;
		return <div id="rayde-studio-stale" class="rayde-stale flex items-center px-3 shrink-0" height={26}>
			<text class="text-xs text-text-secondary truncate">Showing the last version that ran</text>
		</div>;
	}

	static function label(state:String, stale:Bool):String
		return stale ? "Showing the last version that ran" : switch state {
			case "running": "Running";
			case "exited": "The extension stopped";
			case "unavailable": "rayscript-host was not found";
			case _: "Not running";
		}
}
