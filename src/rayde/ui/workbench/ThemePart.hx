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

/** Part of the workbench, split out of it: ThemePart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class ThemePart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	/** The theme being written, when this project is one: reads the editor's text and puts the theme on the window. */
	var themeStudio:Null<ThemeStudio>;

	/** The Theme Studio of the theme file `file`: it reads the editor's text, and what it writes goes to the editor and the file. */
	function makeThemeStudio(file:String):ThemeStudio {
		var studio = new ThemeStudio(file, () -> wb.documentsPart.buffer(file).get(), text -> {
			wb.documentsPart.localHistory.record(file, wb.documentsPart.buffer(file).get(), text, null, "Theme edit");
			wb.documentsPart.buffer(file).set(text);
			sys.io.File.saveContent(file, text);
			wb.documentsPart.localHistory.saved(file, text, null);
			wb.dirty.set([for (d in wb.dirty.get()) if (d != file) d]);
		}, () -> wb.appearance);
		// What is wrong with the theme is a problem of its file: underlined in the editor and listed with the others.
		new ashui.reactive.Watch(() -> studio.problems.get(), list -> {
			var text = wb.documentsPart.buffer(file).get();
			wb.problems.set([for (p in wb.problems.get()) if (p.file != file) p].concat([for (p in list) themeProblem(file, text, p)]));
		});
		return studio;
	}

	/** A problem of a theme file as a diagnostic: on the entry it names, or, for text that is not JSON, where the parser stopped. */
	static function themeProblem(file:String, text:String, p:rayde.theme.ThemeFile.Problem):Diagnostic {
		var span = p.at == null ? null : JsonLocator.find(text, p.at);
		var start = span != null ? span.keyStart : 0, end = span != null ? span.keyEnd : 0;
		if (span == null) {
			var stopped = ~/at position (\d+)/;
			if (stopped.match(p.message)) {
				start = Std.parseInt(stopped.matched(1));
				end = start + 1;
			}
		}
		var from = JsonLocator.position(text, start), to = JsonLocator.position(text, end);
		return {file: file, range: {start: {line: from.line, character: from.character}, end: {line: to.line, character: to.character}}, severity: StringTools.startsWith(p.message, "Invalid JSON") ? 1 : 2, message: p.message};
	}

	/** The theme being written, when this project is one. */
	public function themeModel():Null<ThemeStudio>
		return themeStudio;

	/** Brings the Theme Studio page forward. */
	public function openThemeStudio():Void
		if (themeStudio != null)
			wb.openFile(Workbench.THEME_TAB);

	/** Opens the theme file as text, with the cursor on the entry at `at` (`dark.colors.primary`) when the text has it. */
	function openThemeText(at:Null<String>):Void {
		if (themeStudio == null)
			return;
		var file = themeStudio.file, span = at == null ? null : JsonLocator.find(wb.documentsPart.buffer(file).get(), at);
		if (span == null)
			wb.openFile(file);
		else {
			var where = JsonLocator.position(wb.documentsPart.buffer(file).get(), span.keyStart);
			wb.goTo(file, where.line, where.character);
		}
	}

	/** Switches the window to the light or dark scheme and keeps the choice. */
	function pickScheme(scheme:String):Void {
		if (wb.appearance.scheme == scheme)
			return;
		wb.appearance.scheme = scheme;
		wb.appearance.save(wb.props.display.cwd);
		Theming.apply(wb.appearance);
		wb.terminalPart.settingsRevision.set(wb.terminalPart.settingsRevision.get() + 1);
	}
}
