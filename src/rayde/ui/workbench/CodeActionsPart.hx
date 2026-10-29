package rayde.ui.workbench;

import rayde.ui.Contributions.ActivityEntry;
import ashui.components.Breadcrumb;
import ashui.components.ContextMenu;
import ashui.components.ContextMenu.ContextMenuTrigger;
import ashui.components.Button;
import ashui.components.DropdownMenu;
import ashui.components.CodeEditor;
import ashui.components.code.CodeAnnotations.CodeLineActions;
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

/** Part of the workbench, split out of it: CodeActionsPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class CodeActionsPart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	public final codeActions = new CodeActions();

	var codeActionProviders:CodeActionProviders;

	var entryActions:EntryPointActions;

	final codeActionRevision = Signal.make(0);

	var codeActionVersion = 0;

	var codeActionFile = "";

	var codeActionEditor:Null<CodeEditor>;

	var codeActionTimer:Null<ashui.animation.AnimationScheduler.Timer>;

	var codeActionPoll:Null<ashui.animation.AnimationScheduler.Timer>;

	var codeActionPicker:Null<Int>;

	var requestingActions = false;

	function setupCodeActions():Void {
		codeActions.register("rayde.preview", {id:"extension",extensions:["rays"],kinds:["preview"],automatic:true}, request -> {
			var supported = wb.extension == null;
			codeActions.respond("rayde.preview", request.request, supported ? [{id:"preview",title:"Preview Extension",kind:"preview",icon:"eye",command:"preview-extension",range:{from:0,to:0}}] : []);
		}, (context, _) -> wb.extensionsPart.openPreview(context.path));
		codeActions.register("rayde.preview", {id:"app",languages:["haxe"],kinds:["preview"],automatic:true}, request -> {
			codeActions.respond("rayde.preview", request.request, wb.runPart.canPreviewApp() ? [{id:"app",title:"Preview App",kind:"preview",icon:"eye",command:"preview-app",range:{from:0,to:0}}] : []);
		}, (_, _) -> wb.runPart.previewApp());
		codeActionProviders = new CodeActionProviders(codeActions, wb.props.display.cwd, (owner, name, data) -> {
			if (wb.extensionsPart.extensionManager == null) return;
			var entry = Lambda.find(wb.extensionsPart.extensionManager.extensions, e -> e.connection.file == owner);
			if (entry != null && !entry.disabled) entry.connection.hook(name, data);
		}, (owner, command, args) -> {
			var entry = Lambda.find(wb.extensionsPart.extensionManager.extensions, e -> e.connection.file == owner);
			if (entry != null && !entry.disabled && entry.connection.running()) entry.connection.command(command, args);
		});
		entryActions = new EntryPointActions(codeActions, file -> wb.extension == null && wb.props.empty != true &&
			(wb.props.display.project == null || wb.props.display.project.runnable) && wb.mainFile() == file, wb.runPart.run);
		codeActions.onChanged = () -> {
			if (wb.gone) return;
			codeActionRevision.set(codeActionRevision.get() + 1);
			if (!requestingActions) { updateCodeActionPicker(); wakeCodeActions(); }
		};
		codeActions.onProvidersChanged = () -> {
			if (wb.gone) return;
			var file = wb.active.get(), editor = wb.editorOf(file);
			if (editor != null) queueCodeActions(file, editor, codeActionPicker != null && wb.quickOpen.get());
		};
		codeActions.onError = (owner, message) -> {
			var entry = wb.extensionsPart.extensionManager == null ? null : Lambda.find(wb.extensionsPart.extensionManager.extensions, e -> e.connection.file == owner);
			if (entry != null) entry.connection.note("console", "error", "Code actions: " + message);
		};
	}

	function watchCodeActions(file:String, editor:CodeEditor):Void {
		new ashui.reactive.Watch(() -> editor.value.get(), _ -> queueCodeActions(file, editor));
		new ashui.reactive.Watch(() -> wb.active.get() == file, on -> { if (on) queueCodeActions(file,editor); else editor.actions("code-actions",[]); });
		new ashui.reactive.Watch(() -> [for (p in wb.problems.get()) if (p.file == file) p], _ -> queueCodeActions(file, editor, codeActionPicker != null && wb.quickOpen.get()), LspProtocol.sameDiagnostics);
		new ashui.reactive.Watch(() -> codeActionRevision.get(), _ -> {
			var groups:Array<CodeLineActions> = [], lines = new Map<Int, CodeLineActions>();
			var version = codeActionVersion;
			for (item in codeActions.list()) if (wb.active.get() == file && codeActions.current(file, version)) {
				var line = editor.document.lineAt(item.action.range.from);
				var group = lines.get(line);
				if (group == null) {
					group = {line:line, actions:[]}; lines.set(line,group); groups.push(group);
				}
				var key = item.key;
				group.actions.push({label:item.action.title,icon:ViewIcons.named(null,item.action.icon) ?? Icons.LIGHTBULB_LINE,
					disabled:item.action.disabled != null,run:() -> { executeCodeAction(key,version); }});
			}
			editor.actions("code-actions", groups, true);
		});
		Owner.onCleanup(() -> {
			editor.actions("code-actions", []);
			if (codeActionFile != file || codeActionEditor != editor) return;
			codeActionEditor = null;
			if (codeActionTimer != null) codeActionTimer.cancel(); codeActionTimer = null;
			codeActionVersion++; codeActionFile = ""; codeActionPicker = null; codeActions.clear();
		});
	}

	function queueCodeActions(file:String, editor:CodeEditor, manual = false):Void {
		if (wb.gone || wb.active.get() != file) return;
		codeActionEditor = editor;
		if (codeActionTimer != null) codeActionTimer.cancel();
		codeActionVersion++; codeActionFile = file;
		requestingActions = true; codeActions.clear(); requestingActions = false;
		var version = codeActionVersion;
		codeActionTimer = ashui.animation.AnimationScheduler.main.after(manual ? .01 : .18, () -> {
			codeActionTimer = null;
			if (wb.gone || version != codeActionVersion || wb.active.get() != file || wb.editorOf(file) != editor) return;
			var language = wb.languagesPart.languageServers.language(file) ?? LanguageNames.id(file);
			wb.extensionsPart.extensionManager.codeActions(language);
			var text = editor.value.get(), anchor = editor.editing.anchor.get(), caret = editor.editing.caret.get();
			var range = manual ? {from:Std.int(Math.min(anchor,caret)),to:Std.int(Math.max(anchor,caret))} : {from:0,to:text.length};
			requestingActions = true;
			var accepted = codeActions.request({path:file,language:language,text:text,version:version,range:range,trigger:manual ? "invoked" : "automatic",
				diagnostics:[for (p in wb.problems.get()) if (p.file == file && p.range != null) {from:offsetOf(text,p.range.start.line,p.range.start.character),to:offsetOf(text,p.range.end.line,p.range.end.character),message:p.message,severity:p.severity}]});
			requestingActions = false; updateCodeActionPicker(!accepted); wakeCodeActions();
		});
	}

	function wakeCodeActions():Void {
		if (codeActionPoll != null) codeActionPoll.cancel(); codeActionPoll = null;
		if (wb.gone) return;
		var delay = entryActions.busy() ? .016 : codeActions.delay();
		if (delay != null) codeActionPoll = ashui.animation.AnimationScheduler.main.after(delay, () -> {
			codeActionPoll = null; if (wb.gone) return;
			entryActions.tick(); codeActions.expire(); wakeCodeActions();
		});
	}

	public function showCodeActions():Void {
		var file = wb.active.get(), editor = wb.editorOf(file);
		if (editor == null) return;
		wb.openPicker("Code actions", [{id:"actions-loading",label:"Loading code actions…",icon:Icons.LIGHTBULB_LINE,run:() -> {}}]);
		codeActionPicker = wb.centerRequest.get().serial;
		queueCodeActions(file, editor, true);
	}

	function updateCodeActionPicker(tooLarge = false):Void {
		if (codeActionPicker == null || !wb.quickOpen.get() || wb.centerRequest.get().serial != codeActionPicker) { codeActionPicker = null; return; }
		if (!tooLarge && !codeActions.current(codeActionFile, codeActionVersion)) return;
		var items = actionChoices(codeActions.list());
		if (codeActions.busy()) items.push({id:"actions-loading",label:"Loading code actions…",icon:Icons.LIGHTBULB_LINE,run:() -> {}});
		if (items.length == 0) items.push({id:"actions-empty",label:tooLarge ? "File is too large for code actions" : "No code actions available",icon:Icons.LIGHTBULB_LINE,run:() -> {}});
		wb.centerRequest.set({text:"",serial:codeActionPicker,picker:{placeholder:"Code actions",items:items}});
	}

	function actionChoices(items:Array<ActionItem>):Array<CenterAction> {
		var version = codeActionVersion, choices:Array<CenterAction> = [];
		for (index => item in items) {
			var key = item.key, disabled = item.action.disabled;
			choices.push({id:"code-action-" + index,label:item.action.title,icon:ViewIcons.named(null,item.action.icon) ?? Icons.LIGHTBULB_LINE,
				shortcut:disabled ?? item.action.kind,run:() -> { if (disabled != null) wb.say(disabled); else executeCodeAction(key, version); }});
		}
		return choices;
	}

	public function executeCodeAction(key:String, version:Int):Bool {
		var file = wb.active.get(), editor = wb.editorOf(file);
		if (editor == null) return false;
		var done = false;
		try done = codeActions.execute(key,file,version,(context, action) -> {
			if (wb.editorOf(file) != editor || context.text != editor.value.get()) return false;
			if (editor.editing.readOnly && action.edits != null && action.edits.length > 0) { wb.say("This document is read-only."); return false; }
			if (action.edits != null && action.edits.length > 0) editor.applyEdits(action.edits);
			return true;
		}) catch (error:Dynamic) wb.say(Std.string(error));
		if (wb.active.get() == file && wb.editorOf(file) == editor) queueCodeActions(file, editor);
		return done;
	}

	/** The text offset of a position, its line and character counted from zero; the end of the line, or of the text, where there is none. */
	static function offsetOf(text:String, line:Int, character:Int):Int {
		var at = 0;
		for (_ in 0...line) {
			var next = text.indexOf("\n", at);
			if (next < 0)
				return text.length;
			at = next + 1;
		}
		var end = text.indexOf("\n", at);
		return Std.int(Math.min(at + character, end < 0 ? text.length : end));
	}
}
