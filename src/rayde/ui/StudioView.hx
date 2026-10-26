package rayde.ui;

import ashui.components.Button;
import rayde.ext.ExtensionStyles;
import ashui.components.DropdownMenu;
import ashui.components.Icon;
import ashui.components.Spinner;
import ashui.reactive.Computed;
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
	?onOutput:Void->Void,
	/** Whether it is a card of its own, as in a tab or beside the code; false where the part of the layout it is in has its own. */
	?framed:Bool,
	/** The surrounding Explorer section provides the header. */
	?header:Bool,
	/** The declared view it shows; none for an extension run on its own, which shows everything it mounts. */
	?view:rayde.ext.Manifest.ViewDecl
};

/**
 * The view of an extension where it is shown: its header, which the extension configures (a title it can change, and
 * the tools its config lists), and under it the view. Beside the tools is a menu of what matters while writing the
 * extension: reload, whether typing reloads, the mocked answers, the console, and how it is running. The nodes of the
 * view belong to the Studio and are only placed here, so what is around them can be built again.
 */
class StudioView extends Component<StudioViewProps> {
	function render():Element {
		return <for {revision in [props.studio.manifestRevision.get()]}>${content()}</for>;
	}

	function content():Element {
		var studio = props.studio, surface = new Ref<Div>();
		var body = <div class="flex flex-col flex-1 min-h-0 min-w-0">
			<if {props.header != false}><div id="rayde-studio-bar" class="rayde-studio-bar flex items-center gap-1 pl-3 pr-2 shrink-0" height={36}>
				<text id="rayde-studio-title" class="rayde-heading flex-1 min-w-0 truncate">${shownTitle(studio)}</text>
				{[for (t in studio.tools(viewId())) tool(t)]}
				<if {studio.development}><for {k in [{state: studio.state.get(), stale: studio.stale.get(), live: studio.live.get()}]}>${menu(k.state, k.stale, k.live)}</for></if>
			</div></if>
			<for {stale in [studio.stale.get()]}>${banner(stale)}</for>
			<div class="relative flex flex-col flex-1 min-h-0 min-w-0">
				<div ref={surface} id="rayde-studio-surface" class="rayde-studio-surface flex flex-col flex-1 min-h-0 overflow-auto"/>
				<if {!studio.hasView(viewId()) || studio.state.get() != "running"}><for {state in [{value:studio.state.get(),progress:studio.progress.get(),failure:studio.failure.get()}]}>${waiting(state.value,state.progress,state.failure)}</for></if>
			</div>
		</div>;
		var node = surface.get().node;
		studio.attach(node, null, viewId());
		ashui.reactive.Owner.onCleanup(() -> studio.detach(node));
		var view:Element = props.framed == false ? <div id="rayde-studio" class="flex flex-col flex-1 min-h-0 min-w-0">{body}</div>
			: <div id="rayde-studio" class="rayde-card flex flex-col flex-1 min-h-0 min-w-0">{body}</div>;
		// The stylesheets the extension ships apply to this view, header and content included.
		ExtensionStyles.mark(view, studio.manifest);
		ashui.reactive.Owner.onCleanup(ExtensionStyles.use(studio.manifest, problem -> studio.connection.note("console", "error", problem)));
		return view;
	}

	function viewId():Null<String>
		return props.view == null ? null : props.view.id;

	/** The title the extension gave its first view with setTitle, or the title another view declares. */
	function shownTitle(studio:Studio):String
		return props.view == null || props.view.id == props.studio.manifest.views[0].id ? studio.title.get() : props.view.title;

	/** One of the tools the extension's config puts in its header. */
	function tool(t:ViewTool):Element {
		var icon = props.studio.manifest == null ? Icons.APPS_LINE : ViewIcons.tool(props.studio.manifest, t);
		return <tooltip label={t.title} side="bottom">
			<button id={"rayde-tool-" + t.id} variant={Ghost} size={Icon} class="rayde-panel-button" disabled={Computed.make(() -> { props.studio.progress.get(); return props.studio.state.get() != "running" || props.studio.connection.starting || !props.studio.hasView(viewId()); })} onClick={_ -> props.studio.tool(t.id)}><icon document={icon} class="size-4"/></button>
		</tooltip>;
	}

	function waiting(state:String,progress:String,failure:String):Element {
		var expected=props.view != null || props.studio.manifest == null || props.studio.manifest.views.length > 0;
		var loading=(state == "starting" || state == "running") && failure == "" && (expected || progress != "");
		return <div id="rayde-studio-loading" class="absolute inset-0 flex flex-col items-center justify-center gap-3 p-4 bg-surface">
			<if {loading}><spinner size={Sm}/></if>
			<text widthPercent={1} class="text-center text-sm text-text-secondary">${failure != "" ? "The extension could not load this view." : loading ? (progress == "" ? "Opening extension view…" : progress) : state == "running" ? "This extension has not opened a view." : "The extension is stopped."}</text>
			<if {!loading}><button id="rayde-studio-loading-output" variant={Outline} size={Sm} onClick={_ -> { if (props.onOutput != null) props.onOutput(); else props.onConsole(); }}>Show Output</button></if>
		</div>;
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
					<dropdown-menu-item id="rayde-menu-live" onSelect={() -> studio.live.set(!studio.live.get())}>${live ? "Disable live reload" : "Enable live reload"}</dropdown-menu-item>
					<dropdown-menu-item id="rayde-menu-mocks" onSelect={() -> props.onMocks()}>Edit mocks…</dropdown-menu-item>
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
			<text class="text-xs text-text-secondary truncate">Showing last successful run</text>
		</div>;
	}

	static function label(state:String, stale:Bool):String
		return stale ? "Showing last successful run" : switch state {
			case "running": "Running";
			case "exited": "Exited";
			case _: "Stopped";
		}
}
