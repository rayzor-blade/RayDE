package rayde.ui;

import ashui.components.Icon;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.theme.ThemeState;
import ashui.ui.Component;
import rayde.lang.Display.Diagnostic;

typedef WelcomeProps = {
	/** The project's name, its runtime (ash or rayzor), and its folder. */
	name:String,
	runtime:String,
	root:String,
	/** The build file, the compiler's version, the source folders as the build names them, and how many Haxe files they hold. */
	build:String,
	haxe:String,
	sources:Array<String>,
	files:Int,
	/** The file of the build's main class, when there is one. */
	main:Null<String>,
	recent:Signal<Array<String>>,
	problems:Signal<Array<Diagnostic>>,
	onOpen:String->Void,
	onFiles:Void->Void,
	onCommands:Void->Void,
	onRun:Void->Void,
	onBuild:Void->Void
};

/**
 * What the editor shows with nothing open, in place of the tab strip: where
 * the project stands and the ways to start. It opens the main class, searches
 * the files, lists the commands and runs the project, each beside its keys, and
 * lists the files opened last. Everything on it comes from the project itself.
 */
class Welcome extends Component<WelcomeProps> {
	function render():Element {
		var mod = Sys.systemName() == "Mac" ? "⌘" : "Ctrl";
		return <div id="rayde-welcome" class="rayde-welcome flex flex-1 min-h-0 items-center justify-center overflow-auto">
			<div class="flex flex-col gap-7 px-10 py-6" width={900}>
				<div class="flex flex-col gap-3">
					<for {dark in [darkScheme()]}>${wordmark(dark)}</for>
					<text class="text-sm text-text-secondary">${"Haxe, running on " + props.runtime}</text>
				</div>
				<div class="flex gap-12">
					<div class="flex flex-col gap-7 flex-1 min-w-0">
						<div class="flex flex-col gap-2">
							<text class="rayde-section">Start</text>
							<div class="flex flex-col gap-1">
								<if {props.main != null}>${action("welcome-main", Icons.HAXE, "Open " + haxe.io.Path.withoutDirectory(props.main), "The project's main class", [], () -> props.onOpen(props.main))}</if>
								${action("welcome-files", Icons.SEARCH_LINE, "Go to file", "Open a file by name", [mod, "P"], props.onFiles)}
								${action("welcome-commands", Icons.COMMAND_LINE, "Show all commands", "Run, save, close, go to line and the rest", ["⇧", mod, "P"], props.onCommands)}
								${action("welcome-run", Icons.PLAY_FILL, "Run the project", "Build " + props.build + " and run it on " + props.runtime, ["F5"], props.onRun)}
								${action("welcome-build", Icons.SETTINGS_3_LINE, "Configure the build", "Target, main class, class paths, libraries, defines", [], props.onBuild)}
							</div>
						</div>
						<div class="flex flex-col gap-2">
							<text class="rayde-section">Recent</text>
							<for {list in [props.recent.get()]}>${recent(list)}</for>
						</div>
					</div>
					<div class="flex flex-col gap-2 shrink-0" width={310}>
						<text class="rayde-section">Project</text>
						${projectCard()}
					</div>
				</div>
			</div>
		</div>;
	}

	/** Whether the theme in use is its dark scheme, read so that a change of scheme draws the page again. */
	function darkScheme():Bool {
		var state = ThemeState.get();
		state.revision.get();
		return state.scheme() == ashui.theme.ColorScheme.Dark;
	}

	/** The wordmark for the scheme, at the size the page gives its heading. */
	function wordmark(dark:Bool):Element
		return new ashui.ui.Svg(Icons.wordmark(dark), {width: 232, height: 70});

	/** One way to start: its icon, what it does, and the keys that do it too. */
	function action(id:String, icon:ashui.svg.SvgDocument, label:String, description:String, keys:Array<String>, run:Void->Void):Element
		return <div id={id} class="rayde-action flex items-center gap-3 px-2 cursor-pointer" height={48} onClick={_ -> run()}>
			<div class="rayde-tile flex items-center justify-center shrink-0" width={36} height={36}><icon document={icon} class="size-4"/></div>
			<div class="flex flex-col flex-1 min-w-0">
				<text class="text-sm">${label}</text>
				<text class="text-xs text-text-tertiary">${description}</text>
			</div>
			<div class="flex items-center gap-1">{[for (k in keys) key(k)]}</div>
		</div>;

	function key(k:String):Element
		return <div class="rayde-kbd flex items-center justify-center"><text class="text-xs">${k}</text></div>;

	function recent(list:Array<String>):Element {
		if (list.length == 0)
			return <div class="px-2 py-1"><text class="text-sm text-text-tertiary">Files you open show up here.</text></div>;
		return <div class="flex flex-col gap-1">{[for (path in list) recentRow(path)]}</div>;
	}

	function recentRow(path:String):Element {
		var root = haxe.io.Path.addTrailingSlash(props.root), relative = StringTools.startsWith(path, root) ? path.substr(root.length) : path;
		return <div id={"welcome-recent-" + ~/[^A-Za-z0-9]+/g.replace(relative, "-")} class="rayde-action flex items-center gap-3 px-2 cursor-pointer" height={36} onClick={_ -> props.onOpen(path)}>
			<icon document={Icons.HAXE} class="size-4 shrink-0"/>
			<text class="text-sm shrink-0">${haxe.io.Path.withoutDirectory(path)}</text>
			<text class="text-xs text-text-tertiary">${haxe.io.Path.directory(relative)}</text>
		</div>;
	}

	/** The project at a glance: what runs it, what builds it, where its source is, and its problems as they stand. */
	function projectCard():Element
		return <div class="rayde-summary flex flex-col gap-4 p-4">
			<div class="flex items-center gap-3">
				<div class="rayde-tile flex items-center justify-center shrink-0" width={36} height={36}><icon document={Icons.FOLDER_3_LINE} class="size-4"/></div>
				<div class="flex flex-col min-w-0">
					<text class="text-sm font-medium">${props.name}</text>
					<text class="text-xs text-text-tertiary">${shortPath(props.root)}</text>
				</div>
			</div>
			<div class="flex flex-col gap-2">
				${fact("Runtime", props.runtime)}
				${fact("Compiler", props.haxe)}
				${fact("Build file", props.build)}
				${fact("Source", props.sources.join(", "))}
				${fact("Files", props.files + (props.files == 1 ? " Haxe file" : " Haxe files"))}
				<for {list in [props.problems.get()]}>${problems(list)}</for>
			</div>
		</div>;

	/** `path` with the home folder as ~, and its start left out when it is long, so it fits on a line. */
	function shortPath(path:String):String {
		var home = Sys.getEnv("HOME"), shown = home != null && home != "" && StringTools.startsWith(path, home) ? "~" + path.substr(home.length) : path;
		return shown.length > 32 ? "…" + shown.substr(shown.length - 31) : shown;
	}

	function fact(label:String, value:String):Element
		return <div class="flex items-center justify-between gap-4">
			<text class="text-xs text-text-tertiary">${label}</text>
			<text class="text-sm">${value}</text>
		</div>;

	function problems(list:Array<Diagnostic>):Element {
		var errors = Lambda.count(list, p -> p.severity == 1), warnings = Lambda.count(list, p -> p.severity == 2);
		return <div class="flex items-center justify-between gap-4">
			<text class="text-xs text-text-tertiary">Problems</text>
			<if {errors > 0}><text class="text-sm text-error">${errors + (errors == 1 ? " error" : " errors") + (warnings > 0 ? ", " + warnings + (warnings == 1 ? " warning" : " warnings") : "")}</text>
			<else><if {warnings > 0}><text class="text-sm text-warning">${warnings + (warnings == 1 ? " warning" : " warnings")}</text>
			<else><text class="text-sm">None</text></if></if>
		</div>;
	}
}
