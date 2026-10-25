package rayde.ui;

import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.ui.Component;

typedef WindowControlsProps = {style:String, chrome:WindowChrome};

/**
 * The window's close, minimize and maximize controls, drawn in the style of a platform: macOS's three round lights
 * (the green one takes the window full screen), Windows's flat buttons, GNOME's round ones or KDE's flat rounded ones.
 * Each is a button, so it takes the keyboard and answers Enter and Space.
 */
class WindowControls extends Component<WindowControlsProps> {
	// The pack's filled line icons become hairlines at eight pixels. Outline the
	// same shapes so the lights retain readable symbols at their native size.
	static function lightGlyph(document:ashui.svg.SvgDocument):ashui.svg.SvgDocument {
		var svg = Xml.parse(document.markup).firstElement();
		svg.set("stroke", "currentColor");
		svg.set("stroke-width", "2");
		svg.set("stroke-linejoin", "round");
		return ashui.svg.SvgDocument.parse(svg.toString());
	}

	static final lightClose = lightGlyph(Icons.CLOSE_LINE);
	static final lightMinimize = lightGlyph(Icons.SUBTRACT_LINE);
	static final lightExpand = lightGlyph(Icons.EXPAND_DIAGONAL_LINE);
	static final lightCollapse = lightGlyph(Icons.COLLAPSE_DIAGONAL_LINE);

	public static final styles = [
		{id: "auto", label: "Platform default"},
		{id: "macos", label: "macOS: lights on the left"},
		{id: "icon", label: "RayDE icon on the left, for a standalone app"},
		{id: "windows", label: "Windows: flat, on the right"},
		{id: "gnome", label: "GNOME: round, on the right"},
		{id: "kde", label: "KDE: flat and rounded, on the right"}
	];

	/** The style a setting asks for: `auto` is the platform's, and on Linux the desktop's. */
	public static function styleFor(setting:String):String {
		if (setting != "auto")
			return setting;
		if (rayde.Platform.standalone())
			return "icon";
		if (rayde.Platform.isMac())
			return "macos";
		return switch Sys.systemName() {
			case "Windows": "windows";
			case _:
				var desktop = Sys.getEnv("XDG_CURRENT_DESKTOP");
				desktop != null && desktop.toUpperCase().indexOf("KDE") >= 0 ? "kde" : "gnome";
		}
	}

	/** Whether the controls sit at the left edge of the bar, as macOS's do. */
	public static function onLeft(style:String):Bool
		return style == "macos" || style == "icon";

	/** How wide the group is, so the other end of the bar can hold the same and keep what is between centred. */
	public static function width(style:String):Int
		return switch style {
			case "macos" | "icon": 88;
			case "windows": 138;
			case "gnome": 108;
			case _: 112;
		}

	function render():Element {
		var c = props.chrome, style = props.style;
		return <div id="rayde-window-controls" class="flex items-center shrink-0" width={width(style)} onPointerDown={e -> e.stopPropagation()}>
			<for {k in [{max: c.maximized.get(), full: c.fullscreen.get(), focused: c.focused.get()}]}>${group(style, k.max, k.full, k.focused)}</for>
		</div>;
	}

	function group(style:String, maximized:Bool, fullscreen:Bool, focused:Bool):Element {
		var c = props.chrome;
		var maximizeLabel = maximized ? "Restore" : "Maximize", fullLabel = fullscreen ? "Exit Full Screen" : "Enter Full Screen";
		return switch style {
			case "macos":
				var lights = <div class="rayde-lights flex items-center gap-2 pl-4">
					<tooltip label="Close" side="bottom"><button id="rayde-win-close" class="rayde-light rayde-light-close" onClick={_ -> c.close()}><icon document={lightClose} class="rayde-glyph"/></button></tooltip>
					<tooltip label="Minimize" side="bottom"><button id="rayde-win-minimize" class="rayde-light rayde-light-minimize" onClick={_ -> c.minimize()}><icon document={lightMinimize} class="rayde-glyph"/></button></tooltip>
					<tooltip label={fullLabel} side="bottom"><button id="rayde-win-fullscreen" class="rayde-light rayde-light-zoom" onClick={_ -> c.toggleFullscreen()}><icon document={fullscreen ? lightCollapse : lightExpand} class="rayde-glyph"/></button></tooltip>
				</div>;
				ashui.css.Identity.of(lights.tree, lights.node.id).setAttribute("data-focused", focused ? "true" : "false");
				lights;
			case "icon":
				// A page that is an app of its own has no window to close or minimise: the icon stands where the buttons would.
				var bitmap = ashui.types.Bitmap.fromBytes(AppIcon.png());
				ashui.reactive.Owner.onCleanup(bitmap.dispose);
				bitmap.shrink(128);
				var image = new ashui.ui.Image(bitmap, {width: 28, height: 28, fit: Contain});
				<div id="rayde-app-icon" class="flex items-center pl-4">{image}</div>;
			case "windows":
				<div class="flex items-stretch ml-auto" height={40}>
					<tooltip label="Minimize" side="bottom"><button id="rayde-win-minimize" class="rayde-caption" onClick={_ -> c.minimize()}><icon document={Icons.SUBTRACT_LINE} class="size-4"/></button></tooltip>
					<tooltip label={maximizeLabel} side="bottom"><button id="rayde-win-maximize" class="rayde-caption" onClick={_ -> c.toggleMaximize()}><icon document={maximized ? Icons.CHECKBOX_MULTIPLE_BLANK_LINE : Icons.CHECKBOX_BLANK_LINE} class="size-3.5"/></button></tooltip>
					<tooltip label="Close" side="bottom"><button id="rayde-win-close" class="rayde-caption rayde-caption-close" onClick={_ -> c.close()}><icon document={Icons.CLOSE_LINE} class="size-4"/></button></tooltip>
				</div>;
			case "gnome":
				<div class="flex items-center gap-2 ml-auto pr-3">
					<tooltip label="Minimize" side="bottom"><button id="rayde-win-minimize" class="rayde-round" onClick={_ -> c.minimize()}><icon document={Icons.SUBTRACT_LINE} class="size-3.5"/></button></tooltip>
					<tooltip label={maximizeLabel} side="bottom"><button id="rayde-win-maximize" class="rayde-round" onClick={_ -> c.toggleMaximize()}><icon document={maximized ? Icons.CHECKBOX_MULTIPLE_BLANK_LINE : Icons.CHECKBOX_BLANK_LINE} class="size-3.5"/></button></tooltip>
					<tooltip label="Close" side="bottom"><button id="rayde-win-close" class="rayde-round" onClick={_ -> c.close()}><icon document={Icons.CLOSE_LINE} class="size-3.5"/></button></tooltip>
				</div>;
			case _:
				<div class="flex items-center gap-1 ml-auto pr-2">
					<tooltip label="Minimize" side="bottom"><button id="rayde-win-minimize" class="rayde-flat" onClick={_ -> c.minimize()}><icon document={Icons.SUBTRACT_LINE} class="size-4"/></button></tooltip>
					<tooltip label={maximizeLabel} side="bottom"><button id="rayde-win-maximize" class="rayde-flat" onClick={_ -> c.toggleMaximize()}><icon document={maximized ? Icons.CHECKBOX_MULTIPLE_BLANK_LINE : Icons.CHECKBOX_BLANK_LINE} class="size-3.5"/></button></tooltip>
					<tooltip label="Close" side="bottom"><button id="rayde-win-close" class="rayde-flat rayde-flat-close" onClick={_ -> c.close()}><icon document={Icons.CLOSE_LINE} class="size-4"/></button></tooltip>
				</div>;
		}
	}
}
