package rayde.ui;

import rayde.workspace.Fs;
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
	?empty:Bool,
	?folder:Bool,
	projects:Array<String>,
	onProject:String->Void,
	onOpenFolder:Void->Void,
	onOpenProject:Void->Void,
	onNewProject:Void->Void,
	/** The build file, compiler version, source folders and indexed file count. */
	build:String,
	haxe:String,
	sources:Array<String>,
	files:Void->Int,
	/** The file of the build's main class, when there is one. */
	main:Null<String>,
	?canRun:Bool,
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
 * to open a workspace, or where the current project stands. Recent workspace
 * paths and recent files stay separate from editor and preview instances.
 */
class Welcome extends Component<WelcomeProps> {
	function render():Element {
		var mod = Sys.systemName() == "Mac" ? "⌘" : "Ctrl";
		return <div id="rayde-welcome" class="rayde-welcome flex flex-col flex-1 min-h-0 items-center overflow-auto">
			<div class="flex flex-col gap-7 px-10 py-6 max-w-full my-auto shrink-0" width={900}>
				<div class="flex flex-col gap-3">
					<for {dark in [darkScheme()]}>${wordmark(dark)}</for>
					<text class="text-sm text-text-secondary">Haxe Integrated Development Environment</text>
				</div>
				<div class="flex gap-12">
					<div class="flex flex-col gap-7 flex-1 min-w-0">
						<div class="flex flex-col gap-2">
							<text class="rayde-section">Start</text>
							<div class="flex flex-col gap-1">
								${action("welcome-open-folder", Icons.FOLDER_OPEN_LINE, "Open Folder…", "Open any folder as a workspace", [], props.onOpenFolder)}
								${action("welcome-open-project", Icons.FILE_CODE_LINE, "Open Project…", "Open a build file or project manifest", [], props.onOpenProject)}
								${action("welcome-new-project", Icons.FOLDER_ADD_LINE, "New Project…", "Create a project from a template", [], props.onNewProject)}
								<if {props.main != null}>${action("welcome-main", Icons.HAXE, "Open " + haxe.io.Path.withoutDirectory(props.main), "The project's main class", [], () -> props.onOpen(props.main))}</if>
								<if {props.empty != true}>${action("welcome-files", Icons.SEARCH_LINE, "Go to file", "Open a file by name", [mod, "P"], props.onFiles)}</if>
								${action("welcome-commands", Icons.COMMAND_LINE, "Show all commands", "Run, save, close, go to line and the rest", ["⇧", mod, "P"], props.onCommands)}
								<if {props.canRun != false}>${action("welcome-run", Icons.PLAY_FILL, "Run the project", "Build " + props.build + " and run it on " + props.runtime, ["F5"], props.onRun)}</if>
								<if {props.build != ""}>${action("welcome-build", Icons.SETTINGS_3_LINE, "Configure the build", "Target, main class, class paths, libraries, defines", [], props.onBuild)}</if>
							</div>
						</div>
						<if {props.empty != true}><div class="flex flex-col gap-2">
							<text class="rayde-section">Recent</text>
							<for {list in [props.recent.get()]}>${recent(list)}</for>
						</div></if>
					</div>
					<div class="flex flex-col gap-2 shrink-0" width={310}>
						<if {props.empty == true}>
							<text class="rayde-section">Recent workspaces</text>
							<if {props.projects.length == 0}><text class="text-sm text-text-tertiary px-2 py-1">Projects and folders you open appear here.</text>
							<else><div id="welcome-projects" class="flex flex-col gap-1 overflow-auto" maxHeight={360}>{[for (path in props.projects) projectRow(path)]}</div></if>
						<else><text class="rayde-section">${props.folder == true ? "Workspace" : "Project"}</text>${projectCard()}</if>
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
			<icon document={FileIcons.of(path)} class="size-4 shrink-0"/>
			<text class="text-sm shrink-0">${haxe.io.Path.withoutDirectory(path)}</text>
			<text class="text-xs text-text-tertiary">${haxe.io.Path.directory(relative)}</text>
		</div>;
	}

	function projectRow(path:String):Element {
		var folder = Fs.isDirectory(path), root = folder ? path : haxe.io.Path.directory(path);
		return <div id={"welcome-project-" + props.projects.indexOf(path)} class="rayde-action flex items-center gap-3 px-2 py-2 cursor-pointer shrink-0" onClick={_ -> props.onProject(path)}>
			<icon document={folder ? Icons.FOLDER_OPEN_LINE : Icons.FILE_CODE_LINE} class="size-4 shrink-0"/>
			<div class="flex flex-col flex-1 min-w-0"><text class="text-sm">${haxe.io.Path.withoutDirectory(root)}</text>
				<text class="text-xs text-text-tertiary">${folder ? "Folder workspace" : haxe.io.Path.withoutDirectory(path)}</text>
				<text class="text-xs text-text-tertiary">${shortPath(root)}</text></div>
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
				<if {props.folder != true}>${fact("Runtime", props.runtime)}${fact("Compiler", props.haxe)}
					${fact("Build file", props.build)}${fact("Source", props.sources.join(", "))}</if>
				<for {count in [props.files()]}>${fact("Files", count + (count == 1 ? " file" : " files"))}</for>
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
