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
import ashui.components.Spinner;
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

/** Part of the workbench, split out of it: ExtensionsPart. It reaches the rest through `wb`. */
@:allow(rayde.ui)
@:allow(rayde.ui.workbench)
class ExtensionsPart {
	final wb:Workbench;

	public function new(wb:Workbench)
		this.wb = wb;

	var extensionsDiscovered = false;

	/** The views the extension of this project has put in the layout. */
	var containers:Array<Container> = [];

	public var extensionManager(default, null):Manager;

	final extensionRevision = Signal.make(0);

	final outputChannel = Signal.make("build");

	var supervisionScheduled = false;

	final extensionOutputKinds = Signal.make(new Array<String>());

	final outputStyleRevision = Signal.make(0);

	final outputSpans = new Map<String, Array<Null<Array<AnsiSpan>>>>();

	final extensionOutputView = new Ref<CodeView>();

	final outputJobs = new OutputJobs();

	var outputScheduled = false;

	var outputRevealChannel:Null<String>;

	var extensionOutputDirty = true;

	final outputKinds = new Map<String, Array<String>>();

	final outputStates = new Map<String, CodeEditorState>();

	final buildOutputSyntax = new OutputHighlighter();

	final outputSyntax = new Map<String, OutputHighlighter>();

	/** The extensions open in the Studio, by their main file, and the one of the file in front, if it is one. */
	final studios = new Map<String, Studio>();

	final activeStudio = Signal.make((null : Null<Studio>));

	/** Namespaced bindings let extensions declare the same local command id. */
	static function extensionKey(id:String, command:String):String return Manager.commandKey(id, command);

	function contributedCommands():Array<CenterAction> {
		if (extensionManager == null) return [];
		var out:Array<CenterAction> = [];
		for (e in extensionManager.enabled()) {
			var m = e.connection.manifest;
			for (c in m.commands) out.push({id: extensionKey(m.id, c.id), label: c.title, icon: ViewIcons.named(m, c.icon) ?? Icons.PUZZLE_LINE,
				run: () -> runExtensionCommand(m.id, c.id, (wb.explorerPart.explorerFocused() ? wb.explorerPart.selectedPath() : null) ?? wb.realFile(wb.active.get()))});
		}
		return out;
	}

	function runExtensionCommand(id:String, command:String, path:Null<String>):Void {
		var kind:Null<String> = path == null ? null : sys.FileSystem.exists(path) && sys.FileSystem.isDirectory(path) ? "folder" : "file";
		if (!extensionManager.command(id, command, {path: path, kind: kind})) wb.say('Extension $id is not running.');
	}

	function contributedMenu(location:String, path:String, kind:String):Array<{extension:Manifest, item:rayde.ext.Manifest.MenuEntry}> {
		var out = [];
		for (e in extensionManager.enabled()) {
			var m = e.connection.manifest;
			for (item in m.menuFor(location, path, kind)) out.push({extension: m, item: item});
		}
		return out;
	}

	/** The Studio running the extension whose main file is `file`, if it is open. */
	public function studioFor(file:String):Null<Studio>
		return studios.get(file);

	static function isExtension(file:String):Bool
		return StringTools.endsWith(file, ".rays");

	/** The Studio for an extension's main file, started the first time it is asked for. */
	function studioOf(file:String):Studio {
		var studio = studios.get(file);
		if (studio != null)
			return studio;
		var own = wb.extension != null && wb.extension.mainPath() == file ? wb.extension : null;
		studio = new Studio(file, () -> wb.documentsPart.buffer(file).get(), wb.tree, own);
		studios.set(file, studio);
		studio.services = services();
		studio.debug.load(wb.debugPart.readBreakpoints());
		studio.debug.onChange = () -> wb.debugPart.saveBreakpoints(studio.debug);
		studio.debug.onStop = stop -> wb.debugPart.showStop(studio, stop);
		studio.onTabs = list -> wb.syncTabs(studio, list);
		studio.onProblems = list -> wb.problems.set([for (p in wb.problems.get()) if (p.file != file) p].concat(list));
		studio.onError = kind -> {
			if (wb.panelsPart.panelShown.get())
				return;
			wb.panelsPart.showPanel(kind == "syntax" || kind == "compile" ? "problems" : "extension");
		};
		studio.reload();
		return studio;
	}

	function startExtensions():Void {
		extensionManager = new Manager(wb.props.display.cwd, {builtins: Extensions.builtins(), user: haxe.io.Path.join([Extensions.home(), ".rayde", "extensions"]),
			defaultEvents: ["onStartup"], restartLimit: 3, restartWindow: 60});
		wb.contributions.status({id:"extensions-loading",place:"right",order:350,build:loadingStatus});
		wb.projectPart.projectStarters.onChanged = () -> wb.projectPart.starterRevision.set(wb.projectPart.starterRevision.get() + 1);
		extensionManager.onDiscover = entry -> {
			var m = entry.connection.manifest, dev = entry.installed.scope == "Development";
			if (dev) { entry.connection.source = () -> wb.documentsPart.buffer(entry.connection.file).get(); entry.connection.useMocks = true; }
			var studio = new Studio(m.mainPath(), () -> entry.connection.source(), wb.tree, m, entry.connection);
			studio.managed = true;
			studio.development = dev;
			studio.live.set(dev);
			studios.set(m.mainPath(), studio);
			studio.onTabs = list -> wb.syncTabs(studio, list);
			studio.onProblems = list -> wb.problems.set([for (p in wb.problems.get()) if (p.file != studio.file) p].concat(list));
			entry.onDisabled = disabled -> {
				if (disabled) { studio.clearView(); wb.syncTabs(studio, []); }
			};
			if (dev) {
				studio.debug.load(wb.debugPart.readBreakpoints());
				studio.debug.onChange = () -> wb.debugPart.saveBreakpoints(studio.debug);
				studio.debug.onStop = stop -> wb.debugPart.showStop(studio, stop);
			}
		};
		extensionManager.onChanged = () -> {
			extensionRevision.set(extensionRevision.get() + 1);
			if (!supervisionScheduled && Lambda.exists(extensionManager.extensions, e -> !e.disabled && !e.restartBlocked && e.activation != null && e.connection.state == "exited")) {
				supervisionScheduled = true;
				ashui.animation.AnimationScheduler.main.after(.016, superviseExtensions);
			}
		};
		extensionManager.onOutput = entry -> {
			if (outputChannel.get() == "ext:" + entry.installed.id) {
				extensionOutputDirty = true;
				if (wb.panelsPart.panelShown.get() && wb.panelsPart.bottom.get() == "console") refreshExtensionOutput();
			}
		};
		if (wb.props.empty != true) discoverExtensions(true);
	}

	function loadingStatus():Element {
		function pending():Array<String> {
			extensionRevision.get();
			var messages=[];
			for (entry in extensionManager.extensions) {
				var studio=studios.get(entry.connection.file), message=studio == null ? entry.connection.progress() : studio.loadingMessage();
				if (message != "") messages.push(entry.installed.name + " · " + message);
			}
			return messages;
		}
		return <for {items in [pending()]}><if {items.length > 0}>
			<tooltip label={items.join("\n")} side="top"><div id="rayde-extensions-loading" class="rayde-status-item flex gap-1.5"><spinner size={Sm}/><text maxWidth={240} class="truncate">${items.length == 1 ? items[0] : "Preparing extensions…"}</text></div></tooltip>
		</if></for>;
	}

	function discoverExtensions(start:Bool):Void {
		if (extensionsDiscovered) return;
		extensionsDiscovered = true;
		extensionManager.discover(services(), Extensions.disabled(wb.props.display.cwd), wb.extension);
		refreshExtensionBindings();
		if (start) ashui.animation.AnimationScheduler.main.after(.016, () -> { if (!wb.gone) extensionManager.start(); });
	}

	function superviseExtensions():Void {
		supervisionScheduled = false;
		if (wb.gone) return;
		extensionManager.tick(null, false);
	}

	function refreshExtensionBindings():Void {
		var keys = [], owners = new Map<String, Array<String>>();
		for (e in extensionManager.extensions) {
			var m = e.connection.manifest;
			for (command in m.commands) {
				var old = "ext." + command.id, targets = owners.get(old);
				if (targets == null) { targets = []; owners.set(old, targets); }
				targets.push(extensionKey(m.id, command.id));
			}
			if (!e.disabled) for (key in m.keybindings) keys.push({command: extensionKey(m.id, key.command), key: key.key});
		}
		wb.keymapPart.bindings.setContributions(keys);
		wb.keymapPart.bindings.migrateExtensions(wb.props.display.cwd, owners);
	}

	function toggleExtension(id:String, disabled:Bool):Void {
		Extensions.setDisabled(wb.props.display.cwd, id, disabled);
		extensionManager.setDisabled(id, disabled);
		containers = makeContainers();
		if (!wb.contributions.hasSidebar(wb.sideView.get()) && !Lambda.exists(containers, c -> c.id == wb.sideView.get())) wb.sideView.set("explorer");
		wb.open.set([for (f in wb.open.get()) if (!Workbench.isViewTab(f) || wb.containerOfTab(f) != null) f]);
		if (wb.open.get().indexOf(wb.active.get()) < 0) wb.active.set(wb.open.get().length == 0 ? "" : wb.open.get()[0]);
		wb.commandList.splice(0, wb.commandList.length);
		for (a in wb.shellPart.commands()) wb.commandList.push(a);
		refreshExtensionBindings();
		wb.keymapPart.bindingsChanged();
		wb.layoutRevision.set(wb.layoutRevision.get() + 1);
	}

	function refreshExtensionOutput():Void {
		var channel = outputChannel.get();
		if (channel == "build") return;
		var kinds = outputKinds.exists(channel) ? outputKinds.get(channel) : [];
		if (extensionOutputKinds.get() != kinds) extensionOutputKinds.set(kinds);
		var entry = extensionManager.find(channel.substr(4));
		outputJobs.request(channel, entry == null ? [] : entry.output, entry == null ? [] : entry.outputKinds);
		extensionOutputDirty = false;
		if (!outputScheduled) {
			outputScheduled = true;
			ashui.animation.AnimationScheduler.main.after(.016, pollOutput);
		}
	}

	function pollOutput():Void {
		if (wb.gone) return;
		for (result in outputJobs.poll()) if (result.value != null) {
			var next = result.value, channel = result.key;
			if (channel != "build" && channel != outputChannel.get()) continue;
			var previous = outputSpans.get(channel), changedStyle = !AnsiOutput.sameSpans(previous, next.spans);
			if (changedStyle) { outputSpans.set(channel, next.spans); outputStyleRevision.set(outputStyleRevision.get() + 1); }
			outputState(channel).value.set(next.text);
			if (channel != "build") {
				var kinds = extensionOutputKinds.get(), changed = kinds.length != next.kinds.length;
				if (!changed) for (i in 0...kinds.length) if (kinds[i] != next.kinds[i]) { changed = true; break; }
				if (changed) extensionOutputKinds.set(next.kinds);
				outputKinds.set(channel, extensionOutputKinds.get());
			}
		}
		outputScheduled = outputJobs.busy();
		if (outputScheduled) ashui.animation.AnimationScheduler.main.after(.016, pollOutput);
		else if (outputRevealChannel != null) {
			var reveal = outputRevealChannel == outputChannel.get();
			outputRevealChannel = null;
			if (reveal) ashui.animation.AnimationScheduler.main.after(.016, () -> revealExtensionOutput());
		}
	}

	function outputState(channel:String):CodeEditorState {
		var state = outputStates.get(channel);
		if (state == null) {
			state = new CodeEditorState(channel == "build" ? wb.runPart.consoleText : Signal.make(""));
			outputStates.set(channel, state);
		}
		return state;
	}

	function revealExtensionOutput(tries = 0):Void {
		if (wb.gone || !wb.panelsPart.panelShown.get() || wb.panelsPart.bottom.get() != "console" || outputChannel.get() == "build") return;
		if (outputScheduled) { outputRevealChannel = outputChannel.get(); return; }
		var view = extensionOutputView.get();
		var bounds = view == null ? null : view.tree.getBounds(view.node);
		if (view == null || view.scroll == null || bounds == null || bounds.height <= 0) {
			if (tries < 20) ashui.animation.AnimationScheduler.main.after(.01, () -> revealExtensionOutput(tries + 1));
			return;
		}
		var end = view.value.get().length;
		view.select(end, end);
		view.scroll.scrollTo(0, 1e12);
	}

	function showOutput(studio:Studio):Void {
		if (!studio.managed || studio.manifest == null) { wb.panelsPart.showPanel("extension"); return; }
		outputChannel.set("ext:" + studio.manifest.id);
		refreshExtensionOutput();
		wb.panelsPart.showPanel("console");
		ashui.animation.AnimationScheduler.main.after(.01, () -> revealExtensionOutput());
	}

	/** What an extension may ask of the workbench through `rayde.workspace`. */
	function services():Services
		return {
			registerCodeActions:wb.codeActionsPart.codeActionProviders.register,
			unregisterCodeActions:wb.codeActionsPart.codeActionProviders.unregister,
			respondCodeActions:wb.codeActionsPart.codeActionProviders.respond,
			invalidateCodeActions:wb.codeActionsPart.codeActionProviders.invalidate,
			releaseCodeActions:wb.codeActionsPart.codeActionProviders.release,
			registerStarter:wb.projectPart.projectStarters.register,
			unregisterStarter:wb.projectPart.projectStarters.unregister,
			releaseStarters:wb.projectPart.projectStarters.release,
			registerLanguage:(owner, definition, log) -> wb.languagesPart.languageServers.register(owner, definition, log),
			unregisterLanguage:(owner, id) -> wb.languagesPart.languageServers.unregister(owner, id),
			languageServers:owner -> wb.languagesPart.languageServers.servers(owner),
			releaseLanguages:owner -> wb.languagesPart.languageServers.release(owner),
			imageBytes: wb.imageBytes,
			readBytes: p -> {
				var bytes = wb.imageBytes(p);
				return bytes == null ? null : haxe.crypto.Base64.encode(bytes);
			},
			readFile: p -> {
				var full = wb.projectPath(p, true);
				wb.documentsPart.buffers.exists(full) ? wb.documentsPart.buffers.get(full).get() : sys.FileSystem.exists(full) && !sys.FileSystem.isDirectory(full) ? sys.io.File.getContent(full) : null;
			},
			activeFile: () -> wb.realFile(wb.active.get()),
			root: () -> wb.props.display.cwd,
			openFile: p -> wb.openFile(wb.projectPath(p, true)),
			setStatus: setExtensionStatus,
			focusView: (file, root) -> {
				var id = Workbench.TAB + file + "#" + root;
				if (wb.open.get().indexOf(id) >= 0) wb.active.set(id);
			},
			openExternal: url -> {
				var result = switch Sys.systemName() {
					case "Mac": Sys.command("open", [url]);
					case "Windows": Sys.command("rundll32", ["url.dll,FileProtocolHandler", url]);
					case _: Sys.command("xdg-open", [url]);
				};
				if (result != 0) throw "Cannot open external link";
			},
			writeFile: (p, text) -> {
				var full = wb.projectPath(p);
				var b = wb.documentsPart.buffers.get(full), before = b != null ? b.get() : sys.FileSystem.exists(full) ? sys.io.File.getContent(full) : "";
				wb.documentsPart.localHistory.record(full, before, text, null, "Extension edit");
				sys.io.File.saveContent(full, text);
				wb.documentsPart.localHistory.saved(full, text, null);
				if (b != null)
					b.set(text);
				wb.dirty.set([for (d in wb.dirty.get()) if (d != full) d]);
				wb.explorerPart.refreshExplorer();
			},
			notify: (id, title, message, kind) -> Toaster.show({title:title, description:message,
				variant:kind == "error" ? Destructive : kind == "warning" ? Warning : kind == "success" ? Success : Default,
				duration:kind == "error" ? 10 : 5,
				action:{label:"Show Output", run:() -> {
					outputChannel.set("ext:" + id);
					refreshExtensionOutput();
					wb.panelsPart.showPanel("console");
					ashui.animation.AnimationScheduler.main.after(.01, () -> revealExtensionOutput());
				}}}),
			replay: replayOf
		};

	/** What a hook reports about the present, told to an extension when it starts listening for it. */
	function replayOf(name:String):Dynamic
		return switch name {
			case "active.changed": ({path: wb.realFile(wb.active.get())} : Dynamic);
			case "project.opened": ({root: wb.props.display.cwd} : Dynamic);
			case _: null;
		};

	/** An extension's view in the part of the layout it was given, under its own heading. */
	function extensionBody(c:Container, style:String):Element {
		var studio = studios.get(c.extension.mainPath());
		if (studio == null)
			return <div/>;
		return <div id={"rayde-view-" + c.id} class="rayde-explorer flex flex-col flex-1 min-w-0 min-h-0">
			<studio-view studio={studio} framed={false} view={c.view} onMocks={() -> openMocks(studio)} onConsole={() -> wb.panelsPart.showPanel("extension")} onOutput={() -> showOutput(studio)}/>
		</div>;
	}

	/** What decides where the extension's views are and how their headers look: when it changes, the layout is made again. */
	static function layoutKey(m:Manifest):String
		return haxe.Json.stringify({views:m.views, styles:m.styles, id:m.id});

	/** The form changed the extension's config, which has been read again: the Studio and, if the view moved or looks different, the layout follow. */
	function extensionChanged(m:Manifest):Void {
		var before = wb.extension == null ? "" : layoutKey(wb.extension), previousMain = wb.extension == null ? null : wb.extension.mainPath();
		var studio = previousMain == null ? null : studios.get(previousMain);
		var moved = previousMain != null && previousMain != m.mainPath();
		if (moved && studio != null) {
			wb.syncTabs(studio, []);
			studio.stop();
			studios.remove(previousMain);
			wb.problems.set([for (p in wb.problems.get()) if (p.file != previousMain) p]);
		}
		wb.extension = m;
		var entry = extensionManager.find(m.id);
		if (entry != null) entry.connection.useManifest(m);
		if (studio != null) {
			studio.useManifest(m);
			if (moved) { studios.set(m.mainPath(), studio); studio.reload(); }
		}
		wb.commandList.splice(0, wb.commandList.length);
		for (a in wb.shellPart.commands())
			wb.commandList.push(a);
		refreshExtensionBindings();
		wb.keymapPart.refreshShortcuts();
		wb.keymapPart.bindingsRevision.set(wb.keymapPart.bindingsRevision.get() + 1);
		if (layoutKey(m) == before && !moved)
			return;
		containers = makeContainers();
		if (!wb.contributions.hasSidebar(wb.sideView.get()) && !Lambda.exists(containers, c -> c.id == wb.sideView.get() && c.location == "sidebar")) {
			var first = Lambda.find(containers, c -> c.location == "sidebar");
			wb.sideView.set(first == null ? "explorer" : first.id);
		}
		wb.layoutRevision.set(wb.layoutRevision.get() + 1);
	}

	function makeContainers():Array<Container> {
		var out:Array<Container> = [];
		for (e in extensionManager.enabled()) {
			var m = e.connection.manifest;
			for (v in m.views) out.push({id: wb.extension != null && m.id == wb.extension.id ? (v.id == "main" ? "ext" : "ext-" + v.id) : "ext-" + m.id + "-" + v.id,
				title: v.title, icon: ViewIcons.ofView(m, v), location: v.location, view: v, extension: m});
		}
		return out;
	}

	/** The Studio of this project's extension: its main script, run with the project's config. */
	function extensionStudio():Null<Studio>
		return wb.extension == null ? null : studioOf(wb.extension.mainPath());

	final extensionStatusState = new Map<String, String>();

	/** Sets, replaces or (with a null item) removes one of an extension's status items; a null id removes all of them. */
	function setExtensionStatus(owner:String, id:Null<String>, item:Dynamic):Void {
		var prefix = "ext:" + owner + "\n";
		if (id == null) {
			for (key in wb.contributions.statusIds()) if (StringTools.startsWith(key, prefix)) { wb.contributions.removeStatus(key); extensionStatusState.remove(key); }
			return;
		}
		var key = prefix + id;
		if (item == null) {
			wb.contributions.removeStatus(key);
			extensionStatusState.remove(key);
			return;
		}
		var field = (name:String) -> { var value:Dynamic = Reflect.field(item, name); return value == null ? null : (Std.string(value):Null<String>); };
		var next:ExtensionStatus = {owner:owner, id:id, text:Std.string(item.text), icon:field("icon"), detail:field("detail"), detailIcon:field("detailIcon"),
			tooltip:field("tooltip"), view:field("view"), command:field("command")};
		var json = haxe.Json.stringify(next);
		if (extensionStatusState.get(key) == json) return;
		extensionStatusState.set(key, json);
		wb.contributions.status({id:key, place:"left", order:200, build:() -> extensionStatusItem(next)});
	}

	function extensionStatusItem(item:ExtensionStatus):Element {
		var icon = item.icon == null ? null : ViewIcons.named(null, item.icon), detailIcon = item.detailIcon == null ? null : ViewIcons.named(null, item.detailIcon);
		var content = <div id={"rayde-status-" + item.id} class="rayde-status-item action flex" onClick={_ -> extensionStatusPressed(item)}>
			<if {icon != null}><icon document={icon} class="size-3.5"/></if>
			<text>${item.text}</text>
			<if {item.detail != null}><div class="flex items-center gap-1 rayde-status-detail">
				<if {detailIcon != null}><icon document={detailIcon} class="size-3.5"/></if><text>${item.detail}</text>
			</div></if>
		</div>;
		return item.tooltip == null ? content : <tooltip label={item.tooltip} side="top">{content}</tooltip>;
	}

	function extensionStatusPressed(item:ExtensionStatus):Void {
		var extension = Lambda.find(extensionManager.extensions, entry -> entry.connection.file == item.owner);
		if (extension == null || extension.connection.manifest == null) return;
		var id = extension.connection.manifest.id;
		if (item.view != null) {
			var container = Lambda.find(containers, c -> c.extension.id == id && c.view.id == item.view);
			// Showing a view is not toggling it: a status item never folds the sidebar it points at.
			if (container != null && !(container.location == "sidebar" && wb.sideView.get() == container.id && wb.explorerShown.get())) wb.shellPart.chooseContainer(container);
		}
		if (item.command != null) extensionManager.command(id, item.command, null);
	}

	/** An extension: its code, and beside it the Preview of what it draws. */
	function studioPage(file:String, ?selected:Signal<String>):Element {
		var studio = studioOf(file);
		return <tabs-content value={file} class="flex-1 min-h-0">
			<resizable id="rayde-studio-columns" class="flex-1 min-h-0">
				<resizable-panel minSize={200}>${wb.editorPart.activeCodeEditor(file,selected)}</resizable-panel>
				<resizable-panel size={wb.previewWidth} minSize={220}><studio-view studio={studio} onMocks={() -> openMocks(studio)} onConsole={() -> wb.panelsPart.showPanel("extension")} onOutput={() -> showOutput(studio)}/></resizable-panel>
			</resizable>
		</tabs-content>;
	}

	/** Opens the file that answers the extension's remote calls while it is developed, making it when there is none. */
	function openMocks(studio:Studio):Void {
		var path = studio.mocksPath();
		if (!sys.FileSystem.exists(path))
			sys.io.File.saveContent(path, "{\n}\n");
		wb.openFile(path);
	}

	function extensionLog():Element {
		var channel = outputChannel.get(), kinds = extensionOutputKinds.get(), spans = outputSpans.get(channel);
		var syntax = outputSyntax.get(channel);
		if (syntax == null) { syntax = new OutputHighlighter(kinds, spans); outputSyntax.set(channel, syntax); }
		var view:CodeView = <code-view ref={extensionOutputView} id="rayde-extension-output" state={outputState(channel)} highlighter={syntax} tokenStyles={true} lineNumbers={false} folding={false} class="rayde-output flex-1 min-h-0"/>;
		new ashui.reactive.Watch(() -> { outputStyleRevision.get(); extensionOutputKinds.get(); }, _ -> {
			var kinds = extensionOutputKinds.get(), spans = outputSpans.get(channel);
			if (syntax.kinds == kinds && syntax.spans == spans) return;
			syntax.kinds = kinds; syntax.spans = spans;
			view.metrics.syntax = new OutputHighlighter(kinds, spans);
			view.expandAll();
		});
		return view;
	}
}
