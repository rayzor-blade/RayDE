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

using StringTools;

/** Part of the workbench, split out of it: EditorPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class EditorPart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	final imageViews = new Map<String, ImagePreview.ImageViewState>();

	final imageTextModes = new Map<String, Signal<Bool>>();

	final nativeSyntax = new Map<String, Null<TextMateSyntax>>();

	final editorRefs = new Map<String, Ref<CodeEditor>>();

	/** The open files' tabs, the path to the file in front, and its editor; with nothing open, the welcome page alone. */
	function editorCard():Element
		return <div id="rayde-editor-card" class="rayde-card flex flex-col flex-1 min-h-0">
			<for {has in [wb.open.get().length > 0]}>${tabStrip(has)}</for>
			<for {has in [wb.open.get().length > 0]}>${has ? editors() : welcome()}</for>
		</div>;

	function tabLabel(file:String):String
		return file.startsWith(Workbench.HISTORY_TAB) && wb.documentsPart.historyTabs.exists(file) ? "Local: " + haxe.io.Path.withoutDirectory(wb.documentsPart.historyTabs.get(file).file) + " #" + wb.documentsPart.historyTabs.get(file).revision : file == Workbench.THEME_TAB ? (wb.themePart.themeStudio == null ? "Theme" : wb.themePart.themeStudio.theme.get().name) : Workbench.isTab(file) ? wb.tabTitle(file) : file == Workbench.SETTINGS ? "Settings" : Workbench.isViewTab(file) ? viewTabTitle(file) : haxe.io.Path.withoutDirectory(file);

	function viewTabTitle(file:String):String {
		var v = wb.viewOfTab(file);
		return v == null ? "Extension" : v.title;
	}

	function tabIcon(file:String):ashui.svg.SvgDocument {
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

	function tabStrip(has:Bool):Element {
		if (!has)
			return <div/>;
		return <file-tabs files={wb.open} active={wb.active} dirty={wb.dirty} onClose={wb.closeFile} label={tabLabel} icon={tabIcon} trailing={wb.menusPart.editorMenu()}/>;
	}

	function editors():Element {
		return <div class="flex flex-col flex-1 min-h-0">
			<for {file in [wb.active.get() == Workbench.SETTINGS ? Workbench.SETTINGS + ":" + wb.settingsCategory.get() : wb.active.get()]}>${breadcrumb(wb.active.get())}</for>
			<tabs id="rayde-tabs" value={wb.active} class="flex-1 min-h-0">
				<tabs-list indicator={false} class="rayde-nolist"/>
				<for {file in wb.open}>${retainedPage(file)}</for>
			</tabs>
		</div>;
	}

	/** A keyed page keeps its tab shell and extension controls; code views mount only while active. */
	function retainedPage(file:String):Element {
		var content:TabsContent = cast page(file);
		content.tabs.set(wb.active);
		return content;
	}

	function welcome():Element
		return <welcome name={wb.props.name} runtime={wb.runtime()} root={wb.props.display.cwd}
			empty={wb.props.empty == true} folder={wb.props.display.project != null && wb.props.display.project.kind == "folder"}
			projects={rayde.settings.RecentProjects.paths()} onProject={wb.projectPart.openWorkspace} onOpenFolder={() -> wb.projectPart.pickProject("folder")} onOpenProject={() -> wb.projectPart.pickProject("project")} onNewProject={wb.projectPart.newProject}
			build={wb.explorerPart.projectEntry() == null ? "" : haxe.io.Path.withoutDirectory(wb.explorerPart.projectEntry())} haxe={wb.props.empty == true || wb.runtime() == "" ? "" : wb.compilerVersion()} canRun={wb.props.empty != true && (wb.props.display.project == null || wb.props.display.project.runnable)}
			sources={[for (cp in wb.explorerPart.classpaths()) cp.label]} files={() -> wb.explorerPart.projectFiles().length} main={wb.mainFile()} recent={wb.recent} problems={wb.problems}
			onOpen={path -> wb.openFile(path)} onFiles={() -> wb.openCenter()} onCommands={() -> wb.openCenter(">")} onRun={wb.runPart.run} onBuild={wb.openBuild}/>;

	/** Where `file` sits in the project, folder by folder. */
	function breadcrumb(file:String):Element {
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
	function page(file:String):Element {
		if (file.startsWith(Workbench.HISTORY_TAB)) return <tabs-content value={file} class="flex-1 min-h-0"><if {wb.active.get() == file}>${wb.documentsPart.historyPage(file)}</if></tabs-content>;
		if (file == Workbench.THEME_TAB && wb.themePart.themeStudio != null)
			return <tabs-content value={file} class="flex-1 min-h-0">
				<theme-studio-view studio={wb.themePart.themeStudio} appearance={wb.appearance} revision={wb.terminalPart.settingsRevision} onScheme={wb.themePart.pickScheme} onText={wb.themePart.openThemeText} onOpen={name -> wb.openFile(haxe.io.Path.join([wb.props.display.cwd, name]))}/>
			</tabs-content>;
		if (Workbench.isTab(file)) {
			var owner = wb.extensionsPart.studios.get(Workbench.tabStudio(file));
			return <tabs-content value={file} class="flex-1 min-h-0">
				<if {wb.active.get() == file}>{owner == null ? <div/> : <studio-tab studio={owner} root={Workbench.tabRoot(file)}/>}</if>
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
				<settings-page category={wb.settingsCategory} root={wb.props.display.cwd} build={wb.buildModel} rayzor={wb.rayzorManifest()} onEditBuildText={() -> wb.openFile(wb.rayzorManifest())} beforeBuildChange={wb.beforeBuildChange} terminal={wb.terminalPart.terminalSettings} appearance={wb.appearance} bindings={wb.keymapPart.bindings}
					commands={wb.commandList} libraries={wb.libraries} onBuildChanged={wb.buildChanged} onRunnerChanged={() -> { wb.props.display.reload(); wb.runPart.runnerRevision.set(wb.runPart.runnerRevision.get() + 1); }} onTerminalChanged={() -> wb.terminalPart.settingsRevision.set(wb.terminalPart.settingsRevision.get() + 1)}
					onAppearanceChanged={() -> {
						wb.windowStyle.set(WindowControls.styleFor(wb.appearance.windowControls));
						wb.terminalPart.settingsRevision.set(wb.terminalPart.settingsRevision.get() + 1);
					}} onBindingsChanged={wb.keymapPart.bindingsChanged} bindingChanges={wb.keymapPart.bindingsRevision}
					extension={wb.extension} onExtensionChanged={wb.extensionsPart.extensionChanged} onEditExtensionText={() -> wb.openFile(wb.extension.file)}
					manager={wb.extensionsPart.extensionManager} extensionChanges={wb.extensionsPart.extensionRevision} onExtensionToggle={wb.extensionsPart.toggleExtension}
					listening={() -> wb.extension == null ? [] : wb.extensionsPart.extensionStudio().listening()}/>
			</tabs-content>;
		return pageOfFile(file);
	}

	/** The grammar the editor highlights `file` by. */
	static function languageOf(file:String):String
		return StringTools.endsWith(file, ".hx") || StringTools.endsWith(file, ".rays") ? "haxe" : StringTools.endsWith(file, ".json") || StringTools.endsWith(file, ".rayext") || StringTools.endsWith(file, ".raytheme") ? "json" : "plain";

	function pageOfFile(file:String):Element {
		if (ImagePreview.supports(file)) return <tabs-content value={file} class="flex-1 min-h-0"><if {wb.active.get() == file}>${imagePage(file)}</if></tabs-content>;
		if (ExtensionsPart.isExtension(file) && wb.extension == null)
			return wb.extensionsPart.studioPage(file);
		return <tabs-content value={file} class="flex-1 min-h-0">${activeCodeEditor(file)}</tabs-content>;
	}

	function activeCodeEditor(file:String):Element
		return <if {wb.active.get() == file}>${codeEditor(file)}</if>;

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
		if (languageOf(file) == "plain" && !nativeSyntax.exists(file)) nativeSyntax.set(file, TextMateSyntax.forFile(file));
		var editor = <code-editor ref={editorRef(file)} id={"rayde-editor-" + haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(file))} state={wb.documentsPart.documentState(file)} readOnly={Computed.make(() -> wb.contributions.readOnly(file))} language={languageOf(file)} highlighter={nativeSyntax.get(file)} findShortcuts={false}
			lineNumbers={true} folding={true} indentGuides={true} highlightBrackets={true} minimap={true} gutterMarkers={true} onNavigate={offset -> wb.definitionAt(file, offset)} hover={offset -> wb.editorMarksPart.hintAt(file, offset)} tabSize={4} insertSpaces={false} onInput={_ -> {
				wb.documentsPart.edited(file);
				wb.assistInput(file);
			}}
			class="rayde-code-editor flex-1 min-h-0"/>;
		wb.editorMarksPart.holdCaretWhileScrolling(editorRef(file).get());
		wb.editorMarksPart.annotate(file, editorRef(file).get());
		wb.assistWatch(file, editorRef(file).get());
		var mounted = editorRef(file).get(), state = wb.documentsPart.documents.get(file);
		wb.codeActionsPart.watchCodeActions(file, mounted);
		wb.contributions.editorMade(file, mounted);
		Owner.onCleanup(() -> { wb.assist.stop(file, mounted); state.compact(); });
		return editor;
	}
}
