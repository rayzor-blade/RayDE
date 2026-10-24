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

/** Part of the workbench, split out of it: LanguagesPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class LanguagesPart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	var diagnosticJobs:DiagnosticJobs;

	public var languageServers(default, null):LanguageServers;

	final languageStatusRevision = Signal.make(0);

	final languageActivityRevision = Signal.make(0);

	final languageRevision = Signal.make(0);

	var languagesScheduled = false;

	var languagePollTimer:Null<ashui.animation.AnimationScheduler.Timer>;

	var diagnosticsScheduled = false;

	function wakeLanguages(urgent = true):Void {
		if (wb.gone || !languageServers.busy()) {
			if (languagePollTimer != null) languagePollTimer.cancel();
			languagePollTimer = null;
			languagesScheduled = false;
			return;
		}
		if (languagesScheduled && !urgent) return;
		if (languagePollTimer != null) languagePollTimer.cancel();
		var delay = urgent ? .016 : languageServers.pollDelay();
		if (delay == null) { languagePollTimer = null; languagesScheduled = false; return; }
		languagesScheduled = true;
		languagePollTimer = ashui.animation.AnimationScheduler.main.after(delay, pollLanguages);
	}

	function pollLanguages():Void {
		if (languagePollTimer != null) languagePollTimer.cancel();
		languagePollTimer = null;
		languagesScheduled = false;
		if (wb.gone || !languageServers.busy()) return;
		languageServers.tick();
		wakeLanguages(false);
	}

	/** Asks the compiler what is wrong with `file` as it is in the editor. */
	public function check(file:String):Void {
		if (!Workbench.isVirtual(file) && languageServers != null && languageServers.client(file) != null) {
			diagnosticJobs.cancel(file);
			languageServers.sync(file, wb.documentsPart.buffer(file).get());
			return;
		}
		if (Workbench.isVirtual(file) || !StringTools.endsWith(file, ".hx"))
			return;
		diagnosticJobs.request(file, wb.documentsPart.buffer(file).get());
		wakeDiagnostics();
	}

	function wakeDiagnostics():Void {
		if (wb.gone || diagnosticsScheduled) return;
		diagnosticsScheduled = true;
		ashui.animation.AnimationScheduler.main.after(.03, pollDiagnostics);
	}

	function pollDiagnostics():Void {
		if (wb.gone) return;
		for (result in diagnosticJobs.tick()) {
			var source = wb.documentsPart.buffers.get(result.file);
			var valid = result.lsp ? languageServers.client(result.file) != null && (source == null || source.get() == result.text)
				: languageServers.client(result.file) == null && source != null && source.get() == result.text && wb.open.get().indexOf(result.file) >= 0;
			var current = wb.problems.get();
			if (valid && !LspProtocol.sameDiagnostics([for (p in current) if (p.file == result.file) p], result.problems))
				wb.problems.set([for (p in current) if (p.file != result.file) p].concat(result.problems));
		}
		diagnosticsScheduled = diagnosticJobs.busy();
		if (diagnosticsScheduled) ashui.animation.AnimationScheduler.main.after(.03, pollDiagnostics);
	}

	function languageStatus():Null<LanguageServerStatus> {
		languageStatusRevision.get(); languageRevision.get();
		return languageServers.status(wb.active.get());
	}

	function languageServerItem(server:LanguageServerStatus):Element {
		var extension = Lambda.find(wb.extensionsPart.extensionManager.extensions, entry -> entry.connection.file == server.owner);
		var icon = extension == null || extension.connection.manifest == null ? Icons.CODE_S_SLASH_LINE : ViewIcons.of(extension.connection.manifest);
		var running = ["ready", "starting", "restarting"].indexOf(server.state) >= 0;
		if (!running) icon = ViewIcons.inactive(icon);
		var activity = Computed.make(() -> {
			languageActivityRevision.get();
			var current = languageServers.status(wb.active.get());
			return current == null || current.id != server.id ? null : current.activity != null ? current.activity : current.indexing ? "indexing " + haxe.io.Path.withoutDirectory(wb.active.get()) : null;
		});
		var indexing = Computed.make(() -> activity.get() != null);
		var status = Computed.make(() -> activity.get() ?? (server.state == "idle" ? "not started" : server.state));
		var description = Computed.make(() -> server.name + " — " + status.get());
		var label = Computed.make(() -> server.name + (status.get() == "ready" ? "" : " · " + status.get()));
		var picture:Element = <icon document={icon} class="size-3.5 rayde-lsp-icon"/>;
		ashui.css.Identity.of(picture.tree, picture.node.id).bindBooleanAttribute("data-indexing", indexing);
		if (!running) ashui.css.Identity.of(picture.tree, picture.node.id).addClasses(["rayde-lsp-inactive"]);
		else if (server.state == "starting" || server.state == "restarting") ashui.css.Identity.of(picture.tree, picture.node.id).addClasses(["rayde-lsp-working"]);
		return <tooltip id="rayde-lsp-tooltip" label={description} side="top"><dropdown-menu side="top" id="rayde-lsp-menu">
			<dropdown-menu-trigger id="rayde-lsp-status" variant={Ghost} class="rayde-status-item rayde-lsp-status">
				{picture}<text id="rayde-lsp-label" class="rayde-lsp-label">${label}</text>
			</dropdown-menu-trigger>
			<dropdown-menu-content>
				<dropdown-menu-label><text>${description}</text></dropdown-menu-label>
				<dropdown-menu-item id="rayde-lsp-start" disabled={running || server.state == "closing"} onSelect={() -> languageServers.control(server.id, "start")}>Start</dropdown-menu-item>
				<dropdown-menu-item id="rayde-lsp-restart" disabled={server.state == "closing"} onSelect={() -> languageServers.control(server.id, "restart")}>Restart</dropdown-menu-item>
				<dropdown-menu-item id="rayde-lsp-stop" disabled={!running} onSelect={() -> languageServers.control(server.id, "stop")}>Stop</dropdown-menu-item>
				<dropdown-menu-separator/>
				<dropdown-menu-item id="rayde-lsp-settings" onSelect={() -> wb.openSettings("extensions")}>Language Server Settings…</dropdown-menu-item>
				<dropdown-menu-item id="rayde-lsp-output" onSelect={() -> showLanguageOutput(server.owner)}>Show Output</dropdown-menu-item>
			</dropdown-menu-content>
		</dropdown-menu></tooltip>;
	}

	function showLanguageOutput(owner:String):Void {
		var extension = Lambda.find(wb.extensionsPart.extensionManager.extensions, entry -> entry.connection.file == owner);
		if (extension != null) {
			wb.extensionsPart.outputChannel.set("ext:" + extension.installed.id);
			wb.extensionsPart.refreshExtensionOutput();
		}
		wb.panelsPart.showPanel("console");
		ashui.animation.AnimationScheduler.main.after(.01, () -> wb.extensionsPart.revealExtensionOutput());
	}
}
