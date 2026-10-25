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

/** Part of the workbench, split out of it: DocumentsPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class DocumentsPart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	var localHistory:LocalHistory;

	final historyRevision = Signal.make(0);

	final historyPending = new Map<String, Bool>();

	final comparisonTabs = new Map<String, rayde.history.FileComparison>();

	final historyTabs = new Map<String, {file:String, revision:Int, text:String}>();

	final buffers = new Map<String, Signal<String>>();

	final documents = new Map<String, DocumentState>();

	/** The editor's text for `file`, read from disk when first opened. */
	public function buffer(file:String):Signal<String> {
		if (ImagePreview.isRaster(file)) throw "Image files are not text documents";
		var b = buffers.get(file);
		if (b == null) {
			var disk = sys.io.File.getContent(file), recovered = localHistory.recover(file, disk);
			b = Signal.make(recovered);
			buffers.set(file, b);
			if (recovered != disk && wb.dirty.get().indexOf(file) < 0) {
				ashui.animation.AnimationScheduler.main.after(.01, () -> {
					if (wb.gone || !buffers.exists(file)) return;
					if (wb.dirty.get().indexOf(file) < 0) wb.dirty.set(wb.dirty.get().concat([file]));
					wb.say("Recovered unsaved changes in " + haxe.io.Path.withoutDirectory(file));
				});
			}
		}
		return b;
	}

	function documentState(file:String):DocumentState {
		var state = documents.get(file);
		if (state == null) {
			state = new DocumentState(buffer(file));
			DocumentHistory.restore(state, localHistory.undo(file, state.value.get()));
			documents.set(file, state);
		}
		return state;
	}

	/** Closed saved files need no cache. Unsaved text and live development previews still do. */
	function releaseClosedDocuments():Void {
		var opened = wb.open.get(), changed = wb.dirty.get();
		opened = opened.concat(wb.contributions.retained()).concat([for (comparison in comparisonTabs) comparison.file]);
		if (wb.languagesPart.languageServers != null) wb.languagesPart.languageServers.retain(opened);
		for (file in wb.editorPart.imageViews.keys()) if (opened.indexOf(file) < 0 && changed.indexOf(file) < 0) wb.editorPart.imageViews.remove(file);
		for (file in wb.editorPart.imageTextModes.keys()) if (opened.indexOf(file) < 0 && changed.indexOf(file) < 0) wb.editorPart.imageTextModes.remove(file);
		for (file in localHistory.files()) if (opened.indexOf(file) < 0 && changed.indexOf(file) < 0) localHistory.forget(file);
		for (file in wb.editorPart.nativeSyntax.keys())
			if (opened.indexOf(file) < 0 && changed.indexOf(file) < 0) {
				var syntax = wb.editorPart.nativeSyntax.get(file);
				if (syntax != null) syntax.dispose();
				wb.editorPart.nativeSyntax.remove(file);
			}
		for (file in documents.keys())
			if (opened.indexOf(file) < 0 && changed.indexOf(file) < 0)
				documents.remove(file);
		for (file in wb.editorPart.editorRefs.keys())
			if (opened.indexOf(file) < 0)
				wb.editorPart.editorRefs.remove(file);
		for (file in buffers.keys())
			if (opened.indexOf(file) < 0 && changed.indexOf(file) < 0 && !wb.extensionsPart.studios.exists(file)
				&& (wb.themePart.themeStudio == null || wb.themePart.themeStudio.file != file))
				buffers.remove(file);
	}

	/** Records that `file`'s buffer has changed since it was last written, and checks it as it now is. */
	public function edited(file:String):Void {
		wb.contributions.edited(file);
		checkpointHistory(file);
		if (wb.dirty.get().indexOf(file) < 0)
			wb.dirty.set(wb.dirty.get().concat([file]));
		wb.languagesPart.check(file);
		var studio = wb.extensionsPart.studios.get(file);
		if (wb.themePart.themeStudio != null && file == wb.themePart.themeStudio.file)
			wb.themePart.themeStudio.edited();
		if (studio != null)
			studio.edited();
		else if (wb.extension != null && ExtensionsPart.isExtension(file))
			wb.extensionsPart.extensionStudio().edited();
		wb.emit("file.changed", {path: file}, .3);
		wb.debugPart.followBreakpoints(file);
	}

	function checkpointHistory(file:String):Void {
		var state = documents.get(file), text = buffer(file).get();
		var before = localHistory.current(file, text);
		localHistory.record(file, before, text, state == null ? null : DocumentHistory.snapshot(state), "Edit", wb.contributions.authorOf(file) ?? "Local edit");
		if (historyPending.exists(file)) return;
		historyPending.set(file, true);
		ashui.animation.AnimationScheduler.main.after(.35, () -> { historyPending.remove(file); if (!wb.gone) localHistory.flush(file); });
	}

	public function openComparison(?file:String, ?revision:Int):Void {
		file = wb.realFile(file ?? wb.active.get());
		if (file == null || ImagePreview.isRaster(file)) { wb.say("Open a text file to compare its history."); return; }
		var id=Workbench.DIFF_TAB + file;
		var text=buffer(file).get();
		if (text.indexOf("\x00") >= 0) { wb.say("History diff is available for text files."); return; }
		if (!comparisonTabs.exists(id)) comparisonTabs.set(id,new rayde.history.FileComparison(file,text));
		if (revision != null) { comparisonTabs.get(id).update(text,localHistory.snapshot(file,text),wb.contributions.comparisonOf(file)); comparisonTabs.get(id).refresh(); comparisonTabs.get(id).choose("local:" + revision); }
		wb.openFile(id);
	}
	function closeComparisonsUnder(path:String):Void {
		for (id in [for (id => comparison in comparisonTabs) if (FileOps.inside(path,comparison.file)) id]) wb.closeFile(id);
	}

	function comparisonPage(id:String):Element {
		var comparison=comparisonTabs.get(id);
		if (comparison == null) return <div/>;
		var file=comparison.file;
		return new HistoryDiff({comparison:comparison,buffer:buffer(file),
			journal:() -> localHistory.snapshot(file,buffer(file).get()),source:() -> wb.contributions.comparisonOf(file),onOpen:() -> wb.openFile(file)});
	}

	function previewHistory(file:String, revision:Int):Void {
		var id = Workbench.HISTORY_TAB + file + "#" + revision;
		historyTabs.set(id, {file:file, revision:revision, text:localHistory.revision(file, buffer(file).get(), revision)}); wb.openFile(id);
	}

	function restoreHistory(file:String, text:String):Void {
		wb.openFile(file);
		var attempts = 0;
		function apply():Void {
			var editor = wb.editorOf(file);
			if (editor != null && wb.active.get() == file) editor.applyEdits([{from:0, to:buffer(file).get().length, text:text}]);
			else if (!wb.gone && ++attempts < 80) ashui.animation.AnimationScheduler.main.after(.02, apply);
		}
		ashui.animation.AnimationScheduler.main.after(.02, apply);
	}

	function historyPage(id:String):Element {
		var entry = historyTabs.get(id);
		if (entry == null) return <div/>;
		var text = entry.text;
		return <div class="flex flex-col flex-1 min-h-0">
			<div class="flex items-center gap-2 px-3 py-2 shrink-0 border-b">
				<text class="text-xs text-text-secondary flex-1">Local revision ${Std.string(entry.revision)} · ${haxe.io.Path.withoutDirectory(entry.file)}</text>
				<tooltip label="Compare this revision with the live buffer" side="bottom"><button id="rayde-history-compare" variant={Ghost} size={Icon} onClick={_ -> openComparison(entry.file,entry.revision)}><icon document={Icons.FILE_HISTORY_LINE} class="size-4"/></button></tooltip>
				<tooltip label="Restore this revision to the unsaved buffer; the change can be undone" side="bottom"><button id="rayde-history-restore" variant={Ghost} size={Icon} onClick={_ -> restoreHistory(entry.file, text)}><icon document={Icons.HISTORY_LINE} class="size-4"/></button></tooltip>
			</div>
			<code-view id="rayde-history-preview" value={text} language={EditorPart.languageOf(entry.file)} lineNumbers={true} minimap={false} class="flex-1 min-h-0"/>
		</div>;
	}
}
