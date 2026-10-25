package rayde.ui.workbench;

import rayde.workspace.Fs;
import rayde.ui.Contributions.ActivityEntry;
import ashui.components.Breadcrumb;
import ashui.components.ContextMenu;
import ashui.components.ContextMenu.ContextMenuTrigger;
import ashui.components.Button;
import ashui.components.DropdownMenu;
import ashui.components.CodeEditor;
import ashui.components.code.CodeEditorState;
import ashui.components.CodeView;
import ashui.components.Icon;
import ashui.components.Resizable;
import ashui.components.Select;
import ashui.components.Tabs;
import ashui.components.Tooltip;
import ashui.components.Toast;
import ashui.components.TreeView;
import ashui.layout.Element;
import ashui.reactive.Owner;
import ashui.reactive.Computed;
import ashui.reactive.Signal;
import ashui.input.Events.KeyEvent;
import ashui.ui.Component;
import ashui.types.Style;
import ashui.ui.Ref;
import rayde.build.HxmlFile;
import rayde.actions.CodeActions;
import rayde.actions.CodeAction;
import rayde.actions.EntryPointActions;
import rayde.ext.CodeActionProviders;
import rayde.ext.Manifest;
import rayde.ext.Manager;
import rayde.ext.Manager.ManagedExtension;
import rayde.settings.Extensions;
import rayde.ext.Manifest.ViewDecl;
import rayde.files.FileOps;
import rayde.files.FileIndex;
import rayde.history.LocalHistory;
import rayde.ext.Studio;
import rayde.keys.Chord;
import rayde.keys.KeyBindings;
import rayde.keys.Keymaps;
import rayde.lang.Display;
import rayde.lang.LanguageServers;
import rayde.lang.LanguageServers.LanguageServerStatus;
import rayde.lang.LspProtocol;
import rayde.run.LibraryManager;
import rayde.run.Runner;
import rayde.run.DiagnosticJobs;
import rayde.run.OutputJobs;
import rayde.run.AnsiOutput;
import rayde.run.AnsiOutput.AnsiSpan;
import rayde.settings.Appearance;
import rayde.settings.Store;
import rayde.settings.WorkspaceSession;
import rayde.settings.WorkspaceSession.TabSession;
import rayde.theme.JsonLocator;
import rayde.theme.ThemeFile;
import rayde.theme.ThemeStudio;
import rayde.ext.Debugger;
import rayde.term.Profiles;
import rayde.term.Profiles.Profile;
import rayde.term.Settings;
import rayde.run.Tasks;
import rayde.term.Terminal;
import rayde.ui.FileTabs;
import rayde.ui.Prompt;
import rayde.ui.NewProject;
import rayde.ui.Prompt.PromptRequest;
import rayde.ui.SettingsPage;
import rayde.ui.StudioPanels;
import rayde.ui.StudioTab;
import rayde.ui.StudioView;
import rayde.ui.ThemeStudioView;
import rayde.ui.TerminalView;
import rayde.ui.Welcome;
import rayde.ui.CommandCenter;
import rayde.ui.*;
import rayde.ui.workbench.Types;

using StringTools;

/** Part of the workbench, split out of it: ExplorerPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class ExplorerPart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	/**
	 * What the Explorer's tree shows selected, which the tree writes when a row is
	 * clicked. It is not `active`, which only a file may be: it comes back to the
	 * file in front after a click on a folder, and rests on the top-most closed
	 * folder above that file while one is closed.
	 */
	public final treeSelected = Signal.make("");

	/** Whether each folder of the Explorer is open, kept when the tree is built again. */
	final explorerFilesSize = Signal.make(Math.NaN);

	final explorerSections = new Map<String, ExplorerSection>();

	final dependenciesRevision = Signal.make(0);

	var dependencyReadRoots:Array<String> = [];

	final folderOpen = new Map<String, Signal<Bool>>();

	/** Bumped when a folder first has an open state, so the selection looks at it. */
	final folderStates = Signal.make(0);

	final fileIndex = new FileIndex();

	final moveJobs = new rayde.run.Worker<{root:String, from:String, dir:String}, Null<{from:String,to:String,dir:String}>>((request, cancelled) -> {
		if (cancelled()) return null;
		return {from:request.from, to:FileOps.move(request.root, request.from, request.dir), dir:request.dir};
	});
	var movingFile = false;

	final fileIndexRevision = Signal.make(0);

	var fileIndexScheduled = false;

	final explorerMenu = new Ref<ContextMenu>();

	/** Changes when something is cut or copied, so the menu's Paste is enabled or not. */
	final clipboardRevision = Signal.make(0);

	/** The path the Explorer's menu is open on: a file or folder, or the project's folder for the empty part of the tree. */
	final menuTarget = Signal.make("");

	var ignoreRules:Null<rayde.files.GitIgnore>;

	var ignoreRoot = "";

	var ignoreRevision = -1;

	/** Folder selections only expand the tree; every file can be opened. */
	function openExplorerFile(path:String):Void {
		if (!Fs.exists(path) || Fs.isDirectory(path)) return;
		if (Manifest.isManifest(path)) wb.openSettings("extension");
		else if (ThemeFile.isThemeFile(path)) wb.themePart.openThemeStudio();
		else if (path == wb.props.display.hxml || path == wb.projectManifest()) wb.openBuild();
		else wb.openFile(path);
	}

	/** Folds the Explorer away, leaving the activity bar, or brings it back. */
	function toggleExplorer():Void
		wb.treeWidth.set(wb.explorerShown.get() ? Workbench.ACTIVITY : Workbench.ACTIVITY + Workbench.EXPLORER_WIDTH);

	/** Whether the keyboard is on the Explorer or something in it. */
	function explorerFocused():Bool {
		var found = ashui.css.Css.query(wb.tree, wb.node.id, "#rayde-files"), at = ashui.input.Focus.of(wb.tree);
		if (found.length == 0 || at == null)
			return false;
		return at.node.id == found[0] || wb.tree.ancestors(at.node.id).indexOf(found[0]) >= 0;
	}

	/** The Explorer's icon: it takes the side panel back from an extension, or, when it is there already, folds it away. */
	function chooseExplorer():Void {
		if (wb.sideView.get() == "explorer" || !wb.explorerShown.get()) {
			wb.sideView.set("explorer");
			toggleExplorer();
			return;
		}
		wb.sideView.set("explorer");
	}

	function explorer(shown:Bool):Element {
		if (!shown)
			return <div/>;
		if (wb.props.empty == true) return <div id="rayde-files" class="rayde-explorer flex flex-col flex-1 min-w-0 gap-3 p-3">
			<text class="rayde-heading">Explorer</text><text class="text-sm text-text-secondary">No folder open</text>
			<button id="rayde-empty-open-folder" onClick={_ -> wb.projectPart.pickProject("folder")}>Open Folder…</button>
		</div>;
		var files = () -> <context-menu ref={explorerMenu} id="rayde-explorer-menu">
				<context-menu-trigger id="rayde-explorer-trigger">
					<explorer-tree root={wb.props.display.cwd} name={wb.props.name} entries={explorerEntries} head={headRow} icon={wb.editorPart.fileIcon}
						ignored={ignoredPath} opened={startsOpen} state={folderState} selected={treeSelected} onSelect={openExplorerFile}
						onPress={explorerPress} onMove={moveExplorerFile} canMove={() -> !movingFile} revision={() -> wb.buildRevision.get()}/>
				</context-menu-trigger>
				<context-menu-content id="rayde-explorer-menu-content"><for {state in [{target: menuTarget.get(), keys: wb.keymapPart.bindingsRevision.get(), held: clipboardRevision.get()}]}>${explorerItems(state.target)}</for></context-menu-content>
			</context-menu>;
		var sections:Array<Element> = [new ResizablePanel({id:"rayde-explorer-panel-files", size:explorerFilesSize, minSize:60}, [files()])];
		sections.push(explorerSection("outline", false, 180).panel("Outline", () ->
			<explorer-outline display={wb.props.display} languages={wb.languagesPart.languageServers} revision={() -> wb.buildRevision.get() + wb.languagesPart.languageRevision.get()} file={() -> wb.realFile(wb.active.get())} text={file -> wb.documentsPart.buffer(file).get()} onSelect={wb.goTo}/>, []));
		var contributed = [for (c in wb.extensionsPart.containers) if (c.location == "explorer") c];
		var gitTimeline = Lambda.find(contributed, c -> c.view.id == "timeline");
		sections.push(explorerSection("timeline", false, 180).panel("Timeline", () ->
			<div class="flex flex-col flex-1 min-h-0">
			<local-timeline history={wb.documentsPart.localHistory} revision={wb.documentsPart.historyRevision} file={() -> { var file = wb.realFile(wb.active.get()); return file != null && ImagePreview.isRaster(file) ? null : file; }} text={file -> wb.documentsPart.buffer(file).get()} onPreview={wb.documentsPart.previewHistory}/>
				{gitTimeline == null ? <text class="text-xs text-text-secondary px-3 py-2">Enable Git for commit history</text> : explorerView(gitTimeline)}
			</div>, gitTimeline == null ? [] : explorerTools(gitTimeline)));

		for (c in contributed) if (c != gitTimeline)
			sections.push(explorerSection(c.view.id, false, 160).panel(c.title, () -> explorerView(c), explorerTools(c)));

		sections.push(explorerSection("dependencies", false, 160).panel("Dependencies", () ->
			<for {revision in [dependenciesRevision.get()]}><explorer-dependencies root={wb.props.display.cwd} args={wb.props.display.args} folders={outsideFolders()} onOpen={wb.openFile} onPaths={paths -> dependencyReadRoots = paths}/></for>, [
			<tooltip label="Refresh dependencies" side="bottom"><button id="rayde-dependencies-refresh" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> dependenciesRevision.set(dependenciesRevision.get() + 1)}><icon document={Icons.REFRESH_LINE} class="size-3"/></button></tooltip>,
			<tooltip label="Manage libraries" side="bottom"><button id="rayde-dependencies-settings" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> wb.openSettings("libraries")}><icon document={Icons.SETTINGS_3_LINE} class="size-3"/></button></tooltip>
		]));
		return <div id="rayde-files" class="rayde-explorer flex flex-col flex-1 min-w-0 min-h-0">
			<div class="rayde-side-bar flex items-center pl-3 pr-2 shrink-0" height={36}><text class="rayde-heading">Explorer</text></div>
			<resizable id="rayde-explorer-sections" direction="vertical" class="flex-1 min-h-0">{sections}</resizable>
		</div>;
	}

	function explorerTools(c:Container):Array<Element>
		return [for (t in c.view.tools) <tooltip label={t.title} side="bottom"><button id={"rayde-tool-" + t.id} variant={Ghost} size={Icon} class="rayde-panel-button"
			onClick={_ -> wb.extensionsPart.studioOf(c.extension.mainPath()).tool(t.id)}><icon document={ViewIcons.tool(c.extension, t)} class="size-3"/></button></tooltip>];

	function explorerView(c:Container):Element {
		wb.extensionsPart.extensionManager.view(c.extension.id, c.view.id);
		var studio = wb.extensionsPart.studioOf(c.extension.mainPath());
		return <studio-view studio={studio} framed={false} header={false} view={c.view} onMocks={() -> wb.extensionsPart.openMocks(studio)} onConsole={() -> wb.panelsPart.showPanel("extension")} onOutput={() -> wb.extensionsPart.showOutput(studio)}/>;
	}

	function explorerSection(id:String, open:Bool, size:Float):ExplorerSection {
		if (!explorerSections.exists(id)) explorerSections.set(id, new ExplorerSection(id, open, size));
		return explorerSections.get(id);
	}

	/** Whether git ignores a path; the ignore files are read again after each refresh of the Explorer. */
	function ignoredPath(path:String):Bool {
		var rules = gitIgnore(), revision = wb.buildRevision.get();
		if (revision != ignoreRevision) { ignoreRevision = revision; rules.refresh(); }
		return rules.ignored(path);
	}

	/** The rules git ignores files by, for the project that is open. */
	function gitIgnore():rayde.files.GitIgnore {
		if (ignoreRules == null || ignoreRoot != wb.props.display.cwd) {
			ignoreRoot = wb.props.display.cwd;
			ignoreRules = new rayde.files.GitIgnore(ignoreRoot);
		}
		return ignoreRules;
	}

	/** The path of the row of the tree under a point, or null. */
	function rowAt(x:Float, y:Float):Null<String> {
		for (hit in wb.tree.hitTest(x, y))
			for (id in [hit.id].concat(wb.tree.ancestors(hit.id))) {
				var identity = ashui.css.Identity.of(wb.tree, id);
				var path = identity == null ? null : identity.attribute("data-path");
				if (path != null)
					return path;
			}
		return null;
	}

	/** A secondary press on the tree opens the menu for the row under it, after the menu has been given that row's items. */
	function explorerPress(e:ashui.input.Events.PointerEvent):Void {
		if (e.button == null || !e.button.match(Right))
			return;
		// The trigger around the tree would open the menu at once, on the last row's items; it opens once this one's are in.
		e.stopPropagation();
		e.preventDefault();
		var path = rowAt(e.x, e.y);
		menuTarget.set(path == null ? wb.props.display.cwd : path);
		var x = e.x, y = e.y;
		ashui.animation.AnimationScheduler.main.after(.02, () -> {
			var menu = explorerMenu.get();
			if (menu != null)
				menu.openAt(x, y);
		});
	}

	/** The id of a menu item, from its label: `New File…` is `rayde-explorer-new-file`. */
	static function menuId(label:String):String
		return "rayde-explorer-" + [for (w in label.split(" ")) w.toLowerCase().replace("…", "")].join("-");

	function menuItem(label:String, command:Null<String>, run:Void->Void, enabled = true, ?icon:ashui.svg.SvgDocument):Element {
		var keys = command == null ? null : wb.keymapPart.bindings.label(command);
		var item = <context-menu-item id={menuId(label)} shortcut={keys} disabled={!enabled} onSelect={run}>${label}</context-menu-item>;
		// Icons belong to the menu row, outside its label's text flow.
		if (icon != null) item.appendChild(<icon document={icon} class="size-4 shrink-0 text-text-secondary"/>);
		return item;
	}

	function dangerItem(label:String, command:Null<String>, run:Void->Void):Element {
		var keys = command == null ? null : wb.keymapPart.bindings.label(command);
		return <context-menu-item id={menuId(label)} shortcut={keys} destructive={true} onSelect={run}>${label}</context-menu-item>;
	}

	/** The items of the Explorer's menu for a file, a folder or the project's own folder. */
	function explorerItems(path:String):Element {
		var folder = path != "" && Fs.exists(path) && Fs.isDirectory(path), top = path == wb.props.display.cwd;
		var items:Array<Element> = [];
		var contributed = wb.extensionsPart.contributedMenu("explorer/context", path, folder ? "folder" : "file");
		if (!folder && path != "")
			items.push(menuItem("Open", null, () -> openExplorerFile(path)));
		if (!folder && path == wb.projectManifest())
			items.push(menuItem("Edit as Text", null, () -> wb.openFile(path), true, Icons.CODE_S_SLASH_LINE));
		if (!folder && ImagePreview.isSvg(path)) {
			items.push(menuItem("Open Preview", null, () -> { wb.editorPart.imageTextMode(path).set(false); wb.openFile(path); }, true, Icons.IMAGE_LINE));
			items.push(menuItem("Open in Editor", null, () -> { wb.editorPart.imageTextMode(path).set(true); wb.openFile(path); }, true, Icons.CODE_S_SLASH_LINE));
		}
		if (folder) {
			items.push(menuItem("New File…", "newfile", () -> askCreate(path, false)));
			items.push(menuItem("New Folder…", "newfolder", () -> askCreate(path, true)));
		}
		if (contributed.length > 0) {
			if (items.length > 0)
				items.push(<context-menu-separator/>);
			for (entry in contributed) {
				var c = entry.item, m = entry.extension;
				items.push(menuItem(c.title, ExtensionsPart.extensionKey(m.id, c.command), () -> wb.extensionsPart.runExtensionCommand(m.id, c.command, path), true, ViewIcons.named(m, c.icon)));
			}
		}
		if (items.length > 0)
			items.push(<context-menu-separator/>);
		if (!top) {
			items.push(menuItem("Cut", "filecut", () -> copyFile(path, true)));
			items.push(menuItem("Copy", "filecopy", () -> copyFile(path, false)));
		}
		items.push(menuItem("Paste", "filepaste", () -> pasteFiles(folder ? path : haxe.io.Path.directory(path)), fileClipboard != null));
		if (!top)
			items.push(menuItem("Duplicate", "fileduplicate", () -> duplicateFile(path)));
		items.push(<context-menu-separator/>);
		items.push(menuItem("Copy Path", "filecopypath", () -> ashui.input.Clipboard.setText(path)));
		items.push(menuItem("Copy Relative Path", "filecopyrelative", () -> ashui.input.Clipboard.setText(FileOps.relative(wb.props.display.cwd, path))));
		items.push(menuItem(rayde.Platform.isMac() ? "Reveal in Finder" : "Reveal in File Manager", "filereveal", () -> FileOps.reveal(path)));
		if (!top) {
			items.push(<context-menu-separator/>);
			items.push(menuItem("Rename…", "filerename", () -> askRename(path)));
			items.push(dangerItem("Delete…", "filedelete", () -> askDelete(path)));
		}
		items.push(<context-menu-separator/>);
		items.push(menuItem("Refresh", null, refreshExplorer));
		return <div class="flex flex-col">{items}</div>;
	}

	/** Files cut or copied in the Explorer, waiting to be pasted. */
	var fileClipboard:Null<{paths:Array<String>, cut:Bool}>;

	function copyFile(path:String, cut:Bool):Void {
		fileClipboard = {paths: [path], cut: cut};
		clipboardRevision.set(clipboardRevision.get() + 1);
	}

	/** The file or closed folder the Explorer has selected, the one the file commands act on; not the project's own folder. */
	function selectedPath():Null<String> {
		var path = treeSelected.get();
		return path == null || path == "" || path == wb.props.display.cwd || Workbench.isVirtual(path) ? null : path;
	}

	function withSelected(run:String->Void):Void {
		var path = selectedPath();
		if (path != null)
			run(path);
	}

	/** Where a new file goes by key: in the selected folder, beside the selected file, or in the project's own folder. */
	function selectedFolder():String {
		var path = selectedPath();
		if (path == null)
			return wb.props.display.cwd;
		return Fs.exists(path) && Fs.isDirectory(path) ? path : haxe.io.Path.directory(path);
	}

	/** Commits a drop on the provider worker before remapping the open document views. */
	function moveExplorerFile(from:String, dir:String):Void {
		if (movingFile || wb.gone) return;
		var refused = wb.contributions.refusal(from, "renaming");
		if (refused != null) { wb.say(refused); return; }
		movingFile = true;
		moveJobs.submit("move", {root:wb.props.display.cwd,from:from,dir:dir});
		ashui.animation.AnimationScheduler.main.after(.03, pollMove);
	}

	function pollMove():Void {
		if (wb.gone) return;
		for (result in moveJobs.poll()) {
			movingFile = false;
			if (result.error != null) wb.say(result.error);
			else if (result.value != null) {
				var moved = result.value;
				if (moved.from != moved.to) moveTabs(moved.from, moved.to);
				folderState(moved.dir, true).set(true); refreshExplorer();
			}
		}
		if (movingFile) ashui.animation.AnimationScheduler.main.after(.03, pollMove);
	}

	/** Puts what was cut or copied into `dir`: a copy takes a free name, and what was cut is moved, its tabs with it. */
	function pasteFiles(dir:String):Void {
		var held = fileClipboard;
		if (held == null)
			return;
		try {
			for (p in held.paths) {
				if (!Fs.exists(p))
					continue;
				if (held.cut) {
					var to = FileOps.move(wb.props.display.cwd, p, dir);
					if (to != p)
						moveTabs(p, to);
				} else
					FileOps.copy(wb.props.display.cwd, p, dir, FileOps.uniqueName(dir, haxe.io.Path.withoutDirectory(haxe.io.Path.removeTrailingSlashes(p))));
			}
			if (held.cut) {
				fileClipboard = null;
				clipboardRevision.set(clipboardRevision.get() + 1);
			}
			folderState(dir, true).set(true);
			refreshExplorer();
		} catch (e:Dynamic)
			wb.say(Std.string(e));
	}

	function duplicateFile(path:String):Void {
		try {
			FileOps.duplicate(wb.props.display.cwd, path);
			refreshExplorer();
		} catch (e:Dynamic)
			wb.say(Std.string(e));
	}

	/** Builds the tree again from the files as they are. */
	public function refreshExplorer():Void {
		refreshFileIndex();
		wb.buildRevision.set(wb.buildRevision.get() + 1);
	}

	function askCreate(dir:String, folder:Bool):Void
		wb.prompt.set({
			title: folder ? "New Folder" : "New File",
			description: "Create in " + (dir == wb.props.display.cwd ? wb.props.name : FileOps.relative(wb.props.display.cwd, dir)),
			action: "Create",
			hasInput: true,
			placeholder: folder ? "Folder name" : "File name",
			check: FileOps.invalid,
			accept: name -> {
				var made = folder ? FileOps.createFolder(wb.props.display.cwd, dir, name) : FileOps.createFile(wb.props.display.cwd, dir, name);
				folderState(dir, true).set(true);
				refreshExplorer();
				if (!folder)
					wb.openFile(made);
			}
		});

	function askRename(path:String):Void
		wb.prompt.set({
			title: "Rename",
			description: FileOps.relative(wb.props.display.cwd, path),
			action: "Rename",
			hasInput: true,
			value: haxe.io.Path.withoutDirectory(haxe.io.Path.removeTrailingSlashes(path)),
			check: FileOps.invalid,
			accept: name -> {
				var refused = wb.contributions.refusal(path, "renaming");
				if (refused != null) throw refused;
				var to = FileOps.rename(wb.props.display.cwd, path, name);
				moveTabs(path, to);
				refreshExplorer();
			}
		});

	function askDelete(path:String):Void
		wb.prompt.set({
			title: "Delete",
			description: "Permanently delete " + FileOps.summary(path) + ". This cannot be undone.",
			action: "Delete",
			destructive: true,
			accept: _ -> {
				var refused = wb.contributions.refusal(path, "deleting");
				if (refused != null) throw refused;
				for (f in FileOps.under(wb.open.get(), path))
					wb.closeFile(f);
				wb.documentsPart.closeComparisonsUnder(path);
				FileOps.delete(wb.props.display.cwd, path);
				for (f in FileOps.under([for (k in wb.documentsPart.buffers.keys()) k], path))
					wb.documentsPart.buffers.remove(f);
				wb.dirty.set([for (f in wb.dirty.get()) if (FileOps.under([f], path).length == 0) f]);
				refreshExplorer();
			}
		});

	/** A file or folder was renamed: the tabs, buffers and edits under it follow it to the new path. */
	function moveTabs(from:String, to:String):Void {
		wb.documentsPart.closeComparisonsUnder(from);
		wb.documentsPart.localHistory.move(from, to);
		for (entry in wb.documentsPart.historyTabs) if (entry.file == from || entry.file.startsWith(haxe.io.Path.addTrailingSlash(from))) entry.file = to + entry.file.substr(from.length);
		var moved = FileOps.moved(wb.open.get(), from, to);
		for (old => now in FileOps.moved([for (k in wb.editorPart.nativeSyntax.keys()) k], from, to)) {
			var syntax = wb.editorPart.nativeSyntax.get(old);
			if (syntax != null) syntax.dispose();
			wb.editorPart.nativeSyntax.remove(old);
		}
		for (old => now in FileOps.moved([for (k in wb.documentsPart.buffers.keys()) k], from, to)) {
			wb.documentsPart.buffers.set(now, wb.documentsPart.buffers.get(old));
			wb.documentsPart.buffers.remove(old);
		}
		for (old => now in FileOps.moved([for (k in wb.documentsPart.documents.keys()) k], from, to)) {
			wb.documentsPart.documents.set(now, wb.documentsPart.documents.get(old));
			wb.documentsPart.documents.remove(old);
		}
		for (old => now in moved) {
			wb.editorPart.editorRefs.remove(old);
			var studio = wb.extensionsPart.studios.get(old);
			if (studio != null) {
				studio.dispose();
				wb.extensionsPart.studios.remove(old);
			}
		}
		var remap = (f:String) -> moved.exists(f) ? moved.get(f) : f;
		var front = wb.active.get();
		wb.editorPart.groups.remap(remap);
		wb.open.set([for (f in wb.open.get()) remap(f)]);
		wb.dirty.set([for (f in wb.dirty.get()) FileOps.moved([f], from, to).exists(f) ? FileOps.moved([f], from, to).get(f) : f]);
		wb.active.set(remap(front));
	}

	/** Whether the folder `dir` shows its contents; a folder not yet seen takes `initially`. */
	public function folderState(dir:String, initially = false):Signal<Bool> {
		var open = folderOpen.get(dir);
		if (open == null) {
			open = Signal.make(initially);
			folderOpen.set(dir, open);
			folderStates.set(folderStates.get() + 1);
		}
		return open;
	}

	/** The row of the Explorer that stands for the file in front: the file, or the top-most closed folder above it. */
	function selectionRow():String {
		var file = wb.active.get(), root = wb.props.display.cwd;
		if (file == Workbench.SETTINGS)
			return wb.settingsCategory.get() == "build" && wb.props.display.hxml != null ? wb.props.display.hxml : file;
		if (file == "" || !file.startsWith(root))
			return file;
		var chain = [], dir = haxe.io.Path.directory(file);
		while (dir.length > root.length && dir.startsWith(root)) {
			chain.unshift(dir);
			dir = haxe.io.Path.directory(dir);
		}
		for (d in chain) {
			var open = folderOpen.get(d);
			if (open != null && !open.get())
				return d;
		}
		return file;
	}

	/** Puts the tree's selection back on the file in front, or on the closed folder above it, after a click took it elsewhere. */
	function keepSelection():Void {
		var row = selectionRow();
		if (treeSelected.get() != row)
			treeSelected.set(row);
	}

	/** The project's source folders as the build names them: the label as written, and the folder in full. */
	function classpaths():Array<{label:String, dir:String}> {
		if (wb.props.display.project != null && wb.props.display.project.kind == "folder") return [{label:".", dir:wb.props.display.cwd}];
		if (wb.themePart.themeStudio != null)
			return [{label: haxe.io.Path.withoutDirectory(wb.props.display.cwd), dir: wb.props.display.cwd}];
		if (wb.extension != null)
			return wb.extension.sourceDirs();
		var args = wb.props.display.args, out = [], base = wb.props.display.cwd;
		for (i in 0...args.length - 1)
			if (args[i] == "--cwd") base = haxe.io.Path.isAbsolute(args[i + 1]) ? args[i + 1] : haxe.io.Path.join([base, args[i + 1]]);
			else if (args[i] == "-cp" || args[i] == "-p" || args[i] == "--class-path") {
				var dir = haxe.io.Path.isAbsolute(args[i + 1]) ? args[i + 1] : haxe.io.Path.join([base, args[i + 1]]);
				if (Fs.exists(dir) && Fs.isDirectory(dir))
					out.push({label: args[i + 1], dir: dir});
			}
		return out;
	}

	/** The build file in the tree, which opens the form and not the text; for an extension, its config file, which opens its form. */
	/** The project's own file, the first row under its folder. */
	function headRow():Null<{path:String, icon:ashui.svg.SvgDocument}> {
		if (wb.themePart.themeStudio != null) return {path: wb.themePart.themeStudio.file, icon: Icons.PALETTE_LINE};
		if (wb.extension != null) return {path: wb.extension.file, icon: Icons.SETTINGS_3_LINE};
		var entry = projectEntry();
		return entry == null ? null : {path: entry, icon: Icons.SETTINGS_3_LINE};
	}

	function projectEntry():Null<String> return wb.props.display.project == null ? wb.props.display.hxml : wb.props.display.project.kind == "folder" ? null : wb.props.display.project.file;

	/** External source roots belong with the build's libraries in Dependencies. */
	function outsideFolders():Array<{dir:String, label:String}> {
		var seen = new Map<String, Bool>();
		return [for (cp in classpaths()) if (!FileOps.inside(wb.props.display.cwd, cp.dir) && !seen.exists(cp.dir)) {
			seen.set(cp.dir, true); cp;
		}];
	}

	/** Whether a folder starts open: the project's source folders do, and what is inside them. */
	function startsOpen(dir:String):Bool
		return Lambda.exists(classpaths(), cp -> FileOps.inside(dir, cp.dir));

	/** The project's files with the open ones first, in the order of their tabs. */
	function recentFiles():Array<String> {
		var all = projectFiles(), tabs = wb.open.get(), indexed = new Map<String, Bool>(), opened = new Map<String, Bool>();
		for (file in all) indexed.set(file, true);
		for (file in tabs) opened.set(file, true);
		return [for (file in tabs) if (indexed.exists(file)) file].concat([for (file in all) if (!opened.exists(file)) file]);
	}

	function refreshFileIndex():Void {
		if (wb.props.empty == true) return;
		fileIndex.refresh([for (cp in classpaths()) cp.dir]);
		if (fileIndexScheduled || wb.gone) return;
		fileIndexScheduled = true;
		ashui.animation.AnimationScheduler.main.after(.016, pollFileIndex);
	}

	function pollFileIndex():Void {
		fileIndexScheduled = false;
		if (wb.gone) return;
		if (fileIndex.poll()) fileIndexRevision.set(fileIndexRevision.get() + 1);
		if (fileIndex.busy()) {
			fileIndexScheduled = true;
			ashui.animation.AnimationScheduler.main.after(.016, pollFileIndex);
		}
	}

	/** Openable files from the most recent worker snapshot. */
	function projectFiles():Array<String> {
		fileIndexRevision.get();
		return fileIndex.paths;
	}

	/** What is in `dir`, folders first, then Haxe files, then the rest, each by name. */
	function explorerEntries(dir:String):Array<rayde.ui.ExplorerTree.ExplorerEntry> {
		var names = try Fs.readDirectory(dir) catch (_:Dynamic) [];
		var directories = new Map<String, Bool>();
		for (name in names) directories.set(name, Fs.isDirectory(haxe.io.Path.join([dir, name])));
		function rank(name:String):Int return directories.get(name) ? 0 : haxe.io.Path.extension(name).toLowerCase() == "hx" ? 1 : 2;
		names.sort((a, b) -> { var order = rank(a) - rank(b); return order == 0 ? Reflect.compare(a.toLowerCase(), b.toLowerCase()) : order; });
		var entry = projectEntry(), out:Array<rayde.ui.ExplorerTree.ExplorerEntry> = [];
		for (name in names) {
			var path = haxe.io.Path.join([dir, name]);
			if (path != entry) out.push({name: name, path: path, directory: directories.get(name)});
		}
		return out;
	}
}
