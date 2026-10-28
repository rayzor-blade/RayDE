package rayde.ui.workbench;

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
import rayde.ui.EditorGroups;
import rayde.ui.EditorGroups.EditorGroup;
import rayde.ui.EditorGroups.EditorNode;
import rayde.ui.EditorGroups.EditorSplit;

using StringTools;

/** Part of the workbench, split out of it: EditorPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class EditorPart {
	final wb:Workbench;

	public function new(wb:Workbench) {
		this.wb = wb;
		groups = new EditorGroups(wb.active);
		tabDrag = new EditorTabDrag(groups, (group,file) -> groups.select(group,file), (file,group,index) -> { groups.move(file,group,index); focusCurrent(); });
	}

	public final groups:EditorGroups;
	public final tabDrag:EditorTabDrag;
	var focusHook:Null<ashui.layout.LayoutTree->Void>;

	final imageViews = new Map<String, ImagePreview.ImageViewState>();

	final imageTextModes = new Map<String, Signal<Bool>>();

	final nativeSyntax = new Map<String, Null<TextMateSyntax>>();

	final editorRefs = new Map<String, Ref<CodeEditor>>();

	/** The open files' tabs, the path to the file in front, and its editor; with nothing open, the welcome page alone. */
	function editorCard():Element
	{
		Owner.onCleanup(cancelFocus);
		Owner.onCleanup(tabDrag.cancel);
		new ashui.reactive.Watch(() -> ashui.input.WindowState.active.get() && ashui.input.WindowState.visible.get(), on -> { if (!on) tabDrag.cancel(); });
		var area = new Ref<ashui.ui.Div>();
		return <div ref={area} id="rayde-editor-area" class="relative flex flex-col flex-1 min-h-0 min-w-0">
			<for {layout in [groups.layout.get()]}>${groupLayout(layout)}</for>
			<if {tabDrag.file.get() != ""}>
				<div id="rayde-tab-drag-preview" class="rayde-tab-drag-preview flex flex-col" position={Absolute} zIndex={1000} pointerEvents={PointerEvents.None}
					left={Computed.make(() -> (tabDrag.x.get() - dragOrigin(area,true) + 12:Single))}
					top={Computed.make(() -> (tabDrag.y.get() - dragOrigin(area,false) + 12:Single))}>
					${dragLabel()}
					<for {image in [tabDrag.snapshot.get()]}><if {image != null}><div class="rayde-tab-drag-page flex"><canvas id="rayde-tab-drag-thumbnail" width={image.width} height={image.height} paint={image.paint}/></div></if></for>
				</div>
				<if {tabDrag.markerHeight.get() > 0}><div id="rayde-tab-drop-marker" class="rayde-tab-drop-marker" position={Absolute} zIndex={1001} pointerEvents={PointerEvents.None}
					left={Computed.make(() -> (tabDrag.markerX.get() - dragOrigin(area,true):Single))}
					top={Computed.make(() -> (tabDrag.markerY.get() - dragOrigin(area,false):Single))} height={tabDrag.markerHeight}/></if>
			</if>
		</div>;
	}
	function dragOrigin(area:Ref<ashui.ui.Div>, horizontal:Bool):Float {
		var view=area.get(), box=view == null ? null : view.tree.getScrolledBounds(view.node);
		return box == null ? 0 : horizontal ? box.x : box.y;
	}
	function dragLabel():Element {
		var file = tabDrag.file.get(), group = groups.owner(file);
		return FileTabs.preview(tabLabel(file),tabIcon(file),wb.dirty.get().indexOf(file) >= 0,group != null && group.files.get()[0] == file);
	}

	function groupLayout(node:EditorNode):Element return switch node {
		case Group(group): groupCard(group);
		case Split(split):
			var size = Signal.make(Math.NaN);
			// An unsized panel must still fill the remainder when its sibling gets a pixel size.
			var view = <resizable direction={split.direction} class="rayde-editor-split flex-1 min-h-0 min-w-0">
				<resizable-panel size={size} grow={100 * split.ratio.get()} minSize={100}>${groupLayout(split.first)}</resizable-panel>
				<resizable-panel grow={100 * (1 - split.ratio.get())} minSize={100}>${groupLayout(split.second)}</resizable-panel>
			</resizable>;
			new ashui.reactive.Watch(() -> size.get(), value -> {
				var box = view.tree.getBounds(view.node);
				if (box == null || Math.isNaN(value)) return;
				var total = (split.direction == "vertical" ? box.height : box.width) - 8;
				if (total > 0) groups.resize(split, value / total);
			});
			view;
	};

	function groupCard(group:EditorGroup):Element {
		var view = <div id={"rayde-editor-group-" + group.id} class="rayde-editor-group flex flex-col flex-1 min-h-0 min-w-0" onPointerDown={_ -> groups.select(group)} onKeyDown={e -> { if (!tabDrag.key(e) && !e.defaultPrevented) groups.select(group); }}>
			<div id="rayde-editor-card" class="rayde-card flex flex-col flex-1 min-h-0 min-w-0">
				<for {has in [group.files.get().length > 0 || groups.all().length > 1]}>${tabStrip(has,group)}</for>
				<for {has in [group.files.get().length > 0]}>${has ? editors(group) : groups.all().length == 1 ? welcome() : emptyGroup()}</for>
			</div>
		</div>;
		ashui.css.Identity.of(view.tree,view.node.id).bindBooleanAttribute("data-focused",Computed.make(() -> groups.focused.get() == group.id))
			.bindBooleanAttribute("data-split",Computed.make(() -> groups.all().length > 1))
			.bindBooleanAttribute("data-tab-drop",Computed.make(() -> tabDrag.target.get() == group.id));
		Owner.onCleanup(tabDrag.register(group,view));
		ashui.input.Interaction.of(view.node).setFocusable(true);
		return view;
	}

	function emptyGroup():Element return <div class="flex flex-col flex-1 min-h-0 items-center justify-center gap-3 p-4">
		<text class="text-sm text-text-secondary">Open a file in this group</text>
		<button variant={Ghost} size={Sm} onClick={_ -> wb.openCenter()}>Go to File…</button>
	</div>;

	public function splitEditor(direction:String):Void { groups.sync(wb.open.get(),wb.active.get()); groups.split(direction); focusCurrent(); }
	public function focusGroup(backward = false):Void { groups.focusNext(backward); focusCurrent(); }
	public function moveEditor():Void { groups.moveNext(); focusCurrent(); }
	public function joinGroups():Void { groups.join(); focusCurrent(); }
	public function closeGroup():Void { groups.closeGroup(); focusCurrent(); }
	function focusCurrent():Void {
		cancelFocus();
		var group = groups.current();
		var passed = false;
		focusHook = current -> {
			if (current != wb.tree) return;
			// The second flush-hook pass follows the reactions that replace the old pane.
			if (!passed) { passed = true; return; }
			cancelFocus();
			if (wb.gone || groups.current() != group) return;
			var editor = wb.editorOf(group.active.get());
			if (editor != null) editor.focus();
			else {
				var nodes = ashui.css.Css.query(wb.tree,wb.node.id,"#rayde-editor-group-"+group.id);
				if (nodes.length > 0) ashui.input.Focus.set(ashui.input.Interaction.byId(wb.tree,nodes[0]),true);
			}
		};
		ashui.layout.LayoutTree.flushHooks.push(focusHook);
		ashui.core.Work.notify();
	}
	function cancelFocus():Void {
		if (focusHook == null) return;
		var hooks = ashui.layout.LayoutTree.flushHooks;
		for (i in 0...hooks.length) if (Reflect.compareMethods(hooks[i],focusHook)) { hooks.splice(i,1); break; }
		focusHook = null;
	}

	function tabLabel(file:String):String
		return file == Workbench.APP_PREVIEW ? "App Preview" : fileLabel(file);

	function fileLabel(file:String):String
		return file.startsWith(Workbench.DIFF_TAB) && wb.documentsPart.comparisonTabs.exists(file) ? "History: " + haxe.io.Path.withoutDirectory(wb.documentsPart.comparisonTabs.get(file).file) : file.startsWith(Workbench.HISTORY_TAB) && wb.documentsPart.historyTabs.exists(file) ? "Local: " + haxe.io.Path.withoutDirectory(wb.documentsPart.historyTabs.get(file).file) + " #" + wb.documentsPart.historyTabs.get(file).revision : file == Workbench.THEME_TAB ? (wb.themePart.themeStudio == null ? "Theme" : wb.themePart.themeStudio.theme.get().name) : Workbench.isTab(file) ? wb.tabTitle(file) : file == Workbench.SETTINGS ? "Settings" : Workbench.isViewTab(file) ? viewTabTitle(file) : haxe.io.Path.withoutDirectory(file);

	function viewTabTitle(file:String):String {
		var v = wb.viewOfTab(file);
		return v == null ? "Extension" : v.title;
	}

	function tabIcon(file:String):ashui.svg.SvgDocument {
		if (file == Workbench.APP_PREVIEW) return Icons.EYE_LINE;
		if (file.startsWith(Workbench.DIFF_TAB)) return Icons.FILE_HISTORY_LINE;
		if (file.startsWith(Workbench.HISTORY_TAB)) return Icons.HISTORY_LINE;
		if (Workbench.isTab(file)) {
			var studio = wb.extensionsPart.studios.get(Workbench.tabStudio(file));
			return studio != null && studio.manifest != null ? ViewIcons.of(studio.manifest) : Icons.PUZZLE_LINE;
		}
		return file == Workbench.THEME_TAB ? Icons.PALETTE_LINE : file == Workbench.SETTINGS ? Icons.SETTINGS_3_LINE : Workbench.isViewTab(file) && wb.viewOfTab(file) != null ? ViewIcons.ofView(wb.containerOfTab(file).extension, wb.viewOfTab(file)) : fileIcon(file);
	}

	/** The icon a file has in the Explorer and on its tab. */
	function fileIcon(file:String):ashui.svg.SvgDocument
		return FileIcons.of(file);

	function tabStrip(has:Bool, group:EditorGroup):Element {
		if (!has)
			return <div/>;
		var actions = <div class="flex items-center gap-1">
			<if {wb.runPart.canPreviewApp() && haxe.io.Path.extension(group.active.get()).toLowerCase() == "hx"}>
				<tooltip label="Preview App" side="bottom"><button id="rayde-open-app-preview" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> { groups.select(group); wb.runPart.previewApp(); }}><icon document={Icons.EYE_LINE} class="size-4"/></button></tooltip>
			</if>
			<if {ExtensionsPart.isExtension(group.active.get()) && wb.extension == null}>
				<tooltip label="Open Extension Preview" side="bottom"><button id="rayde-open-extension-preview" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> { groups.select(group); wb.extensionsPart.openPreview(group.active.get()); }}><icon document={Icons.EYE_LINE} class="size-4"/></button></tooltip>
			</if>
			<tooltip label={"Split Editor Right (Vertical)" + shortcut("splitright")} side="bottom"><button id="rayde-split-right" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> { groups.select(group); splitEditor("horizontal"); }}><icon document={Icons.LAYOUT_COLUMN_LINE} class="size-4"/></button></tooltip>
			<tooltip label={"Split Editor Down (Horizontal)" + shortcut("splitdown")} side="bottom"><button id="rayde-split-down" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> { groups.select(group); splitEditor("vertical"); }}><icon document={Icons.LAYOUT_ROW_LINE} class="size-4"/></button></tooltip>
			<tooltip label="File History Diff" side="bottom"><button id="rayde-open-history-diff" variant={Ghost} size={Icon} class="rayde-panel-button" disabled={Computed.make(() -> { var file=wb.realFile(group.active.get()); return file == null || ImagePreview.isRaster(file); })} onClick={_ -> { groups.select(group); wb.documentsPart.openComparison(group.active.get()); }}><icon document={Icons.FILE_HISTORY_LINE} class="size-4"/></button></tooltip>
			${wb.menusPart.editorMenu(group)}
		</div>;
		return new TabContextMenu({workbench:wb,group:group,label:tabLabel,icon:tabIcon,trailing:actions});
	}
	function shortcut(command:String):String { wb.keymapPart.bindingsRevision.get(); var label = wb.keymapPart.bindings.label(command); return label == null ? "" : " · " + label; }

	function editors(group:EditorGroup):Element {
		// The inner page starts at its parent's origin for capture; the outer wrapper follows the strip.
		return <div class="flex flex-col flex-1 min-h-0">
			<div class="rayde-tab-page flex flex-col flex-1 min-h-0 min-w-0">
			<for {file in [group.active.get() == Workbench.SETTINGS ? Workbench.SETTINGS + ":" + wb.settingsCategory.get() : group.active.get()]}><if {!codeBreadcrumb(group.active.get())}>${breadcrumb(group.active.get())}</if></for>
			<tabs id="rayde-tabs" value={group.active} class="flex-1 min-h-0">
				<tabs-list indicator={false} class="rayde-nolist"/>
				<for {file in group.files}>${retainedPage(file,group.active)}</for>
			</tabs>
			</div>
		</div>;
	}

	/** A keyed page keeps its tab shell and extension controls; code views mount only while active. */
	function retainedPage(file:String, selected:Signal<String>):Element {
		var content:TabsContent = cast page(file,selected);
		content.tabs.set(selected);
		return content;
	}

	function welcome():Element
		return <welcome name={wb.props.name} runtime={wb.runtime()} root={wb.props.display.cwd}
			empty={wb.props.empty == true} folder={wb.props.display.project != null && wb.props.display.project.kind == "folder"}
			projects={rayde.settings.RecentProjects.paths()} onProject={wb.projectPart.openWorkspace} onOpenFolder={() -> wb.projectPart.pickProject("folder")} onOpenProject={() -> wb.projectPart.pickProject("project")} onNewProject={wb.projectPart.newProject}
			build={wb.explorerPart.projectEntry() == null ? "" : haxe.io.Path.withoutDirectory(wb.explorerPart.projectEntry())} haxe={wb.props.empty == true || wb.runtime() == "" ? "" : wb.compilerVersion()} canRun={wb.props.empty != true && (wb.props.display.project == null || wb.props.display.project.runnable)}
			sources={[for (cp in wb.explorerPart.classpaths()) cp.label]} files={() -> wb.explorerPart.projectFiles().length} main={wb.mainFile()} recent={wb.recent} problems={wb.problems}
			onOpen={path -> wb.openFile(path)} onFiles={() -> wb.openCenter()} onCommands={() -> wb.openCenter(">")} onRun={wb.runPart.run} onBuild={wb.openBuild}/>;

	/** A text editor owns its breadcrumb so its minimap can span the whole page. */
	function codeBreadcrumb(file:String):Bool
		return !file.startsWith("rayde:") && !ImagePreview.supports(file) && !(ExtensionsPart.isExtension(file) && wb.extension == null);

	/** Where `file` sits in the project, folder by folder. */
	function breadcrumb(file:String):Element {
		if (file.startsWith(Workbench.DIFF_TAB) && wb.documentsPart.comparisonTabs.exists(file)) return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs([haxe.io.Path.withoutDirectory(wb.documentsPart.comparisonTabs.get(file).file), "History diff"])}</breadcrumb>;
		if (file.startsWith(Workbench.HISTORY_TAB) && wb.documentsPart.historyTabs.exists(file)) return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs([haxe.io.Path.withoutDirectory(wb.documentsPart.historyTabs.get(file).file), "Local history"])}</breadcrumb>;
		if (file == Workbench.SETTINGS)
			return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs(["Settings", SettingsPage.labelOf(SettingsPage.category(wb.settingsCategory.get()), wb.extension)])}</breadcrumb>;
		if (file == Workbench.THEME_TAB)
			return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs([wb.themePart.themeStudio == null ? "Theme" : wb.themePart.themeStudio.theme.get().name, "Theme Studio"])}</breadcrumb>;
		if (Workbench.isViewTab(file))
			return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs([viewTabTitle(file)])}</breadcrumb>;
		if (Workbench.isTab(file))
			return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs([wb.extension == null ? "Extension" : wb.extension.name, wb.tabTitle(file)])}</breadcrumb>;
		var root = haxe.io.Path.addTrailingSlash(wb.props.display.cwd);
		var parts = (file.startsWith(root) ? file.substr(root.length) : file).split("/");
		return <breadcrumb id="rayde-breadcrumb" size={Sm} class="rayde-crumbs">{crumbs(parts)}</breadcrumb>;
	}

	function crumbs(parts:Array<String>):Array<Element>
		return [for (i => part in parts) <breadcrumb-item current={i == parts.length - 1}>${part}</breadcrumb-item>];

	function editorRef(file:String):Ref<CodeEditor> {
		var ref = editorRefs.get(file);
		if (ref == null) {
			ref = new Ref<CodeEditor>();
			editorRefs.set(file, ref);
		}
		return ref;
	}

	/** One open file's editor, which checks the file as it is typed. */
	function page(file:String, selected:Signal<String>):Element {
		if (file == Workbench.APP_PREVIEW) return <tabs-content value={file} class="flex-1 min-h-0"><if {selected.get() == file && wb.runPart.appPreview != null}><app-preview build={wb.runPart.appPreview} rebuild={wb.runPart.previewApp} shown={() -> !wb.quickOpen.get() && wb.prompt.get() == null && !Lambda.exists([for (opened in wb.extensionsPart.previewSheets) opened], opened -> opened.get())}/></if></tabs-content>;
		if (file.startsWith(Workbench.DIFF_TAB)) return <tabs-content value={file} class="flex-1 min-h-0"><if {selected.get() == file}>${wb.documentsPart.comparisonPage(file)}</if></tabs-content>;
		if (file.startsWith(Workbench.HISTORY_TAB)) return <tabs-content value={file} class="flex-1 min-h-0"><if {selected.get() == file}>${wb.documentsPart.historyPage(file)}</if></tabs-content>;
		if (file == Workbench.THEME_TAB && wb.themePart.themeStudio != null)
			return <tabs-content value={file} class="flex-1 min-h-0">
				<theme-studio-view studio={wb.themePart.themeStudio} appearance={wb.appearance} revision={wb.terminalPart.settingsRevision} onScheme={wb.themePart.pickScheme} onText={wb.themePart.openThemeText} onOpen={name -> wb.openFile(haxe.io.Path.join([wb.props.display.cwd, name]))}/>
			</tabs-content>;
		if (Workbench.isTab(file)) {
			var owner = wb.extensionsPart.studios.get(Workbench.tabStudio(file));
			return <tabs-content value={file} class="flex-1 min-h-0">
				<if {selected.get() == file}>{owner == null ? <div/> : <studio-tab studio={owner} root={Workbench.tabRoot(file)}/>}</if>
			</tabs-content>;
		}
		if (Workbench.isViewTab(file)) {
			var c = wb.containerOfTab(file);
			if (c == null) return <tabs-content value={file} class="flex-1 min-h-0"><div/></tabs-content>;
			var studio = wb.extensionsPart.studios.get(c.extension.mainPath());
			return <tabs-content value={file} class="flex-1 min-h-0">
				<studio-view studio={studio} framed={true} view={wb.viewOfTab(file)} onMocks={() -> wb.extensionsPart.openMocks(studio)} onConsole={() -> wb.panelsPart.showPanel("extension")}/>
			</tabs-content>;
		}
		if (file == Workbench.SETTINGS)
			return <tabs-content value={file} class="flex-1 min-h-0">
				<settings-page category={wb.settingsCategory} root={wb.props.display.cwd} build={null} buildLoad={wb.buildLoad.state} onReloadBuild={() -> wb.buildLoad.load(wb.props.display.hxml)} rayzor={wb.rayzorManifest()} caribou={wb.caribouManifest()} caribouLanguages={() -> wb.props.display.project == null ? [] : wb.props.display.project.languages} onEditBuildText={() -> wb.openFile(wb.projectManifest() ?? wb.props.display.hxml)} beforeBuildChange={wb.beforeBuildChange} terminal={wb.terminalPart.terminalSettings} appearance={wb.appearance} bindings={wb.keymapPart.bindings}
					commands={wb.commandList} libraries={wb.libraries} onBuildChanged={wb.buildChanged} onRunnerChanged={() -> { wb.props.display.reload(); wb.runPart.runnerRevision.set(wb.runPart.runnerRevision.get() + 1); }} onTerminalChanged={() -> wb.terminalPart.settingsRevision.set(wb.terminalPart.settingsRevision.get() + 1)}
					onAppearanceChanged={() -> {
						wb.windowStyle.set(WindowControls.styleFor(wb.appearance.windowControls));
						wb.terminalPart.settingsRevision.set(wb.terminalPart.settingsRevision.get() + 1);
					}} onBindingsChanged={wb.keymapPart.bindingsChanged} bindingChanges={wb.keymapPart.bindingsRevision}
					extension={wb.extension} onExtensionChanged={wb.extensionsPart.extensionChanged} onEditExtensionText={() -> wb.openFile(wb.extension.file)}
					manager={wb.extensionsPart.extensionManager} extensionChanges={wb.extensionsPart.extensionRevision} onExtensionToggle={wb.extensionsPart.toggleExtension}
					listening={() -> wb.extension == null ? [] : wb.extensionsPart.extensionStudio().listening()}/>
			</tabs-content>;
		return pageOfFile(file,selected);
	}

	/** The grammar the editor highlights `file` by. */
	static function languageOf(file:String):String
		return EditorSyntax.languageOf(file);

	function pageOfFile(file:String, selected:Signal<String>):Element {
		if (ThemeFile.isThemeFile(file) && (wb.props.theme == null || wb.props.theme.file != file)) return wb.themePart.filePage(file,selected);
		if (ImagePreview.supports(file)) return <tabs-content value={file} class="flex-1 min-h-0"><if {selected.get() == file}>${imagePage(file)}</if></tabs-content>;
		if (ExtensionsPart.isExtension(file) && wb.extension == null)
			return wb.extensionsPart.studioPage(file,selected);
		return <tabs-content value={file} class="flex-1 min-h-0">${activeCodeEditor(file,selected)}</tabs-content>;
	}

	function activeCodeEditor(file:String, ?selected:Signal<String>):Element {
		var front = selected ?? wb.active;
		return <if {front.get() == file}>${codeEditor(file)}</if>;
	}

	function imageTextMode(file:String):Signal<Bool> {
		if (!imageTextModes.exists(file)) imageTextModes.set(file, Signal.make(false));
		return imageTextModes.get(file);
	}

	function imagePage(file:String):Element {
		if (!imageViews.exists(file)) imageViews.set(file, ImagePreview.state());
		var mode = imageTextMode(file);
		return <for {code in [mode.get()]}>
			<if {code && ImagePreview.isSvg(file)}>
				<div class="flex flex-col flex-1 min-h-0">
					<div class="rayde-image-tools flex items-center justify-between px-3 py-2 shrink-0"><text class="text-xs text-text-secondary">SVG source</text>
						<tooltip label="Open Preview" side="bottom"><button id="rayde-image-show-preview" variant={Ghost} size={Icon} class="rayde-panel-button" onClick={_ -> mode.set(false)}><icon document={Icons.IMAGE_LINE} class="size-4"/></button></tooltip>
					</div>
					${codeEditor(file)}
				</div>
			<else>
				<image-preview file={file} state={imageViews.get(file)} source={ImagePreview.isSvg(file) ? wb.documentsPart.buffer(file) : null} onEdit={ImagePreview.isSvg(file) ? () -> mode.set(true) : null}/>
			</if>
		</for>;
	}

	function codeEditor(file:String):Element {
		if (wb.restoredTabs.remove(file)) wb.languagesPart.check(file);
		var language = languageOf(file);
		#if !(wasm || rayde_page)
		if (language != "haxe" && language != "json" && !nativeSyntax.exists(file)) nativeSyntax.set(file, TextMateSyntax.forFile(file));
		#end
		var highlighterSource:ashui.layout.IntoReactive<Null<ashui.components.code.CodeHighlighter>> = (null:Null<ashui.components.code.CodeHighlighter>);
		#if (wasm || rayde_page)
		var session = rayde.workspace.PageHost.session;
		if (language != "haxe" && language != "json" && session != null && session.syntax) highlighterSource = new SessionSyntax(session,file,wb.documentsPart.buffer(file)).highlighter;
		#end
		var header = codeBreadcrumb(file) ? breadcrumb(file) : null;
		if (header != null) ashui.input.Interaction.of(header.node).onPointerDown(event -> if (event.button != null && event.button.match(Right)) event.stopPropagation());
		var editor = <code-editor ref={editorRef(file)} id={"rayde-editor-" + haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(file))} state={wb.documentsPart.documentState(file)} header={header} readOnly={Computed.make(() -> wb.contributions.readOnly(file))} language={language} highlighter={nativeSyntax.get(file)} highlighterSource={highlighterSource} findShortcuts={false}
			onKey={wb.keymapPart.editorKey}
			lineNumbers={true} folding={true} indentGuides={true} highlightBrackets={true} minimap={true} gutterMarkers={true} stableGutter={true} compactGutter={wb.debugPart.debuggerOf(file) == null} onNavigate={offset -> { var group = groups.owner(file); if (group != null) groups.select(group); wb.definitionAt(file, offset); }} hover={offset -> wb.editorMarksPart.hintAt(file, offset)} tabSize={4} insertSpaces={false} onInput={_ -> {
				wb.documentsPart.edited(file);
				wb.assistInput(file);
			}}
			class="rayde-code-editor flex-1 min-h-0"/>;
		wb.editorMarksPart.holdCaretWhileScrolling(editorRef(file).get());
		wb.editorMarksPart.annotate(file, editorRef(file).get());
		wb.assistWatch(file, editorRef(file).get());
		var mounted = editorRef(file).get(), state = wb.documentsPart.documents.get(file);
		mounted.editing.interaction.onFocus(_ -> { var group = groups.owner(file); if (group != null) groups.select(group,file); });
		wb.codeActionsPart.watchCodeActions(file, mounted);
		wb.contributions.editorMade(file, mounted);
		Owner.onCleanup(() -> { wb.assist.stop(file, mounted); state.compact(); });
		return new EditorContextMenu({workbench:wb,file:file,editor:mounted});
	}
}
