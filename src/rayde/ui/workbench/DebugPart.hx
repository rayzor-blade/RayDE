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

/** Part of the workbench, split out of it: DebugPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class DebugPart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	/** Files whose breakpoints are about to be read back from the editor. */
	final following = new Map<String, Bool>();

	/** Breakpoints move with the text; once the editor has moved them, the debugger learns where they are now. */
	function followBreakpoints(file:String):Void {
		if (following.exists(file) || debuggerOf(file) == null)
			return;
		following.set(file, true);
		ashui.animation.AnimationScheduler.main.after(.03, () -> {
			following.remove(file);
			if (wb.gone)
				return;
			var state = wb.documentsPart.documents.get(file), d = debuggerOf(file);
			if (state != null && state.annotations != null && d != null)
				d.setLines(file, [for (l in state.annotations.markerLinesOf("breakpoints")) l + 1]);
		});
	}

	/** The breakpoints kept for this project, by file. */
	function readBreakpoints():Array<rayde.ext.Debugger.Breakpoint> {
		var saved = Store.section(wb.props.display.cwd, "breakpoints"), out = [];
		for (rel in Reflect.fields(saved)) {
			var lines:Dynamic = Reflect.field(saved, rel);
			if (Std.isOfType(lines, Array))
				for (l in (lines : Array<Dynamic>))
					out.push({file: haxe.io.Path.join([wb.props.display.cwd, rel]), line: Std.int(l)});
		}
		return out;
	}

	function saveBreakpoints(d:Debugger):Void {
		var saved:Dynamic = {};
		for (b in d.breakpoints.get()) {
			var rel = wb.relative(b.file);
			var lines:Array<Int> = Reflect.hasField(saved, rel) ? Reflect.field(saved, rel) : [];
			lines.push(b.line);
			Reflect.setField(saved, rel, lines);
		}
		Store.save(wb.props.display.cwd, "breakpoints", saved);
	}

	/** The extension stopped: its place is shown in the editor and its stack and variables in the panel. */
	function showStop(studio:Studio, stop:rayde.ext.Debugger.Stop):Void {
		var top = stop.frames[0];
		if (top != null && Fs.exists(top.file))
			wb.goTo(top.file, top.line - 1, Std.int(Math.max(0, top.col - 1)));
		studio.panel.set("debug");
		wb.panelsPart.showPanel("extension");
	}

	/** The debugger of the extension in front, if there is one. */
	function debugger():Null<Debugger> {
		var studio = wb.extension != null ? wb.extensionsPart.extensionStudio() : wb.extensionsPart.studios.get(wb.active.get());
		return studio == null ? null : studio.debug;
	}

	/** Puts a breakpoint on the line the cursor is on in the file in front, or takes the one there away. */
	function toggleBreakpoint():Void {
		var file = wb.realFile(wb.active.get());
		var d = debugger();
		if (file == null || !ExtensionsPart.isExtension(file) || d == null) {
			wb.say("Breakpoints go on a line of a RayScript file");
			return;
		}
		var line = wb.caretLine(file);
		if (line < 0)
			return;
		wb.say(d.toggle(file, line + 1) ? "Breakpoint on " + haxe.io.Path.withoutDirectory(file) + ":" + (line + 1) : "Breakpoint removed");
	}

	/** Lets the stopped extension go on as `how` says; said so when none is stopped. */
	function debugResume(how:String):Void {
		var d = debugger();
		if (d == null || d.stopped.get() == null)
			wb.say("The extension is not stopped");
		else
			d.resume(how);
	}

	/** The debugger of the extension `file` is part of, if it is a RayScript file of one. */
	function debuggerOf(file:String):Null<Debugger> {
		if (!ExtensionsPart.isExtension(file))
			return null;
		var studio = wb.extension != null ? wb.extensionsPart.extensionStudio() : wb.extensionsPart.studios.get(file);
		return studio == null ? null : studio.debug;
	}

	/** Marks the line of the frame chosen in the stack when it is in `file`, and nothing otherwise. */
	function markStop(file:String, editor:CodeEditor, d:Debugger):Void {
		var stop = d.stopped.get(), frame = stop == null ? null : stop.frames[d.frame.get()];
		if (frame == null || frame.file != file) {
			editor.decorate("stopped", []);
			return;
		}
		var at = CodeActionsPart.offsetOf(wb.documentsPart.buffer(file).get(), frame.line - 1, 0);
		editor.decorate("stopped", [{from: at, to: at, className: "ui-code-line-current", wholeLine: true}], true);
	}
}
