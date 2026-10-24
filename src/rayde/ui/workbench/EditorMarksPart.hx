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

/** Part of the workbench, split out of it: EditorMarksPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class EditorMarksPart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	/**
	 * What the editor shows beside and in the text: the breakpoints in the gutter, which a click puts on a line or takes
	 * off and which move with the text; the line an extension is stopped on; and the compiler's problems underlined.
	 */
	function annotate(file:String, editor:Null<CodeEditor>):Void {
		if (editor == null)
			return;
		var d = wb.debugPart.debuggerOf(file);
		if (d != null) {
			editor.onGutterClick = (line, e) -> if (e.button == null || e.button.match(Left)) d.toggle(file, line + 1);
			new ashui.reactive.Watch(() -> d.breakpoints.get(), list -> editor.markers("breakpoints", [for (b in list) if (b.file == file) {line: b.line - 1, className: "ui-code-marker-breakpoint", title: "Breakpoint"}], true));
			new ashui.reactive.Watch(() -> {
				d.stopped.get();
				d.frame.get();
				0;
			}, _ -> wb.debugPart.markStop(file, editor, d), (_, _) -> false);
		}
		new ashui.reactive.Watch(() -> wb.problems.get(), list -> {
			var text = wb.documentsPart.buffer(file).get();
			editor.decorate("problems", [for (p in list) if (p.file == file) squiggle(text, p)]);
		});
	}

	/** Documentation for a diagnostic at the pointer, or the language server's type and documentation. */
	function hintAt(file:String, offset:Int):Null<ashui.components.code.CodeHints.CodeHint> {
		var editor = wb.editorOf(file);
		var marked = editor == null ? [] : editor.decorationsAt(offset);
		if (marked.length > 0) {
			var titled = [for (d in marked) if (d.title != null && d.title != "") d];
			if (titled.length == 0) return null;
			var from = titled[0].from, to = titled[0].to;
			for (d in titled) {
				from = Std.int(Math.min(from, d.from));
				to = Std.int(Math.max(to, d.to));
			}
			var message = [for (d in titled) d.title].join("\n\n");
			return {from:from, to:Std.int(Math.max(to, from + 1)),
				className:StringTools.replace(titled[0].className, "squiggle", "hint"),
				renderDocs:() -> HoverDocumentation.render({kind:"markdown", value:message})};
		}
		if (!StringTools.endsWith(file, ".hx") && wb.languagesPart.languageServers.client(file) == null)
			return null;
		var text = wb.documentsPart.buffer(file).get();
		var client = wb.languagesPart.languageServers.client(file);
		if (client != null) {
			if (editor == null || !client.supports("hoverProvider")) return null;
			wb.languagesPart.languageServers.sync(file, text);
			client.request("textDocument/hover", LspProtocol.at(file, text, offset), result -> {
				if (wb.gone || wb.editorOf(file) != editor || editor.value.get() != text || editor.hoverOffset != offset || result == null) return;
				var range:Dynamic = result.range;
				editor.showHint({from:range == null ? offset : LspProtocol.offset(text, range.start),
					to:range == null ? offset + 1 : LspProtocol.offset(text, range.end), renderDocs:() -> HoverDocumentation.render(result.contents)});
			}, file + "#hover");
			return null;
		}
		var found = try wb.props.display.hover(file, Display.byteOffset(text, offset), text) catch (_:Dynamic) null;
		if (found == null || found.range == null)
			return null;
		return {
			from: CodeActionsPart.offsetOf(text, found.range.start.line, found.range.start.character),
			to: CodeActionsPart.offsetOf(text, found.range.end.line, found.range.end.character),
			signature: found.type,
			language: "haxe",
			docs: found.documentation
		};
	}

	function squiggle(text:String, p:Diagnostic):ashui.components.code.CodeAnnotations.CodeDecoration {
		var from = CodeActionsPart.offsetOf(text, p.range.start.line, p.range.start.character), to = CodeActionsPart.offsetOf(text, p.range.end.line, p.range.end.character);
		if (to <= from)
			to = Std.int(Math.min(text.length, from + 1));
		var kind = p.severity == 1 ? "ui-code-squiggle-error" : p.severity == 2 ? "ui-code-squiggle-warning" : "ui-code-squiggle-info";
		return {from: from, to: to, className: kind, title: p.message};
	}

	/** How long the caret stays steady after the last scroll step before it blinks again, in seconds. */
	static inline var CARET_REST = .6;

	/**
	 * Keeps the caret steady while the editor scrolls, and blinking again once it has rested: a blink fades over
	 * several frames, each a full draw, and those compete with the frames of a scroll.
	 */
	function holdCaretWhileScrolling(editor:Null<CodeEditor>):Void {
		if (editor == null || editor.scroll == null)
			return;
		var last = 0., holding = false, check:Void->Void = null;
		var timer:Null<ashui.animation.AnimationScheduler.Timer> = null;
		Owner.onCleanup(() -> {
			if (timer != null) timer.cancel();
			editor = null;
		});
		check = () -> {
			if (editor == null) return;
			var left = CARET_REST - (haxe.Timer.stamp() - last);
			if (left > 0)
				timer = ashui.animation.AnimationScheduler.main.after(left, check);
			else {
				holding = false;
				if (editor.editing.showsCaret())
					editor.editing.restartBlink();
			}
		};
		new ashui.reactive.Watch(() -> editor.scroll.y.get(), _ -> {
			last = haxe.Timer.stamp();
			if (holding)
				return;
			holding = true;
			editor.editing.stopBlink();
			timer = ashui.animation.AnimationScheduler.main.after(CARET_REST, check);
		});
	}
}
