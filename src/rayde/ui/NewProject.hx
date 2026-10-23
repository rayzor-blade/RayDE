package rayde.ui;

import ashui.components.Button;
import ashui.components.Dialog;
import ashui.components.Icon;
import ashui.layout.Element;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.reactive.Watch;
import ashui.ui.Component;
import ashui.ui.Ref;
import rayde.project.ProjectFile;
import rayde.project.ProjectTemplates;
import rayde.project.ProjectTemplates.ProjectTemplate;

typedef NewProjectProps = {
	opened:Signal<Bool>,
	directory:String,
	onCreate:String->Void
};

/** Mounted only while choosing a starter; file operations stay on a data-only worker. */
class NewProject extends Component<NewProjectProps> {
	static final categories = ["All", "Applications", "Games", "Libraries"];
	static final rayzorIcon = ashui.svg.SvgDocument.embed("extensions/rayzor/logo.svg");
	final selected = Signal.make("hxml");
	final category = Signal.make("All");
	final name = Signal.make("my-project");
	final directory = Signal.make("");
	final error = Signal.make("");
	final busy = Signal.make(false);
	final browsing = Signal.make(false);
	final input = new Ref<ashui.ui.Input>();
	final jobs = new rayde.run.Worker<rayde.ui.ProjectPicker.ProjectPickRequest, Null<String>>(ProjectPicker.choose);
	var cancelDialog:Null<Void->Void>;
	var gone = false;

	function render():Element {
		directory.set(props.directory);
		Owner.onCleanup(() -> {
			gone = true;
			if (cancelDialog != null) cancelDialog();
			cancelDialog = null;
			jobs.dispose();
		});
		ashui.animation.AnimationScheduler.main.after(.05, () -> {
			if (!gone && input.get() != null) {
				input.get().focus();
				input.get().editing.anchor.set(0);
				input.get().editing.caret.set(name.get().length);
			}
		});
		return <dialog id="rayde-new-project" open={props.opened}>
			<dialog-content id="rayde-project-modal" size={Full} onCancel={e -> if (locked()) e.preventDefault()}>
				<div class="rayde-project-heading">
					<div class="rayde-project-title">
						<dialog-title>Create a project</dialog-title>
						<dialog-description>Choose a starting point for your next idea.</dialog-description>
					</div>
					<button id="rayde-project-close" variant={Ghost} size={Icon} disabled={locked()} onClick={_ -> close()}><icon document={Icons.CLOSE_LINE} class="size-5"/></button>
				</div>
				<div class="rayde-project-categories">
					<for {group in categories}>${categoryButton(group)}</for>
				</div>
				<div id="rayde-project-catalog" class="rayde-project-catalog">
					<div class="rayde-project-grid"><for {template in ProjectTemplates.matching(category.get())}>${card(template)}</for></div>
				</div>
				<div class="rayde-project-details">
					<icon document={Icons.INFORMATION_LINE} class="size-4 shrink-0"/>
					<div class="rayde-project-detail-text">
						<text id="rayde-project-requirements">${ProjectTemplates.get(selected.get()).requirements}</text>
						<text class="rayde-project-muted">${"Get started: " + ProjectTemplates.get(selected.get()).command}</text>
					</div>
				</div>
				<div class="rayde-project-fields">
					<div class="rayde-project-name-field">
						<label for="rayde-project-name">Project name</label>
						<input ref={input} id="rayde-project-name" value={name} maxlength={64} disabled={locked()} placeholder="my-project" onInput={_ -> error.set("")} onKeyDown={e -> if (e.key.match(Named(Enter))) create()}/>
					</div>
					<div class="rayde-project-location-field">
						<label for="rayde-project-directory">Location</label>
						<div class="rayde-project-location">
							<input id="rayde-project-directory" value={directory} disabled={locked()} placeholder="Parent folder" onInput={_ -> error.set("")} onKeyDown={e -> if (e.key.match(Named(Enter))) create()}/>
							<button id="rayde-project-browse" variant={Outline} disabled={locked()} onClick={_ -> browse()}>Browse…</button>
						</div>
					</div>
				</div>
				<if {error.get() != ""}><text id="rayde-project-error" class="text-xs text-error">${error.get()}</text></if>
				<dialog-footer id="rayde-project-footer">
					<div class="rayde-project-destination"><icon document={Icons.FOLDER_ADD_LINE} class="size-4 shrink-0"/><text id="rayde-project-destination">${destination()}</text></div>
					<button id="rayde-project-cancel" variant={Outline} disabled={locked()} onClick={_ -> close()}>Cancel</button>
					<button id="rayde-project-create" disabled={locked()} onClick={_ -> create()}><icon document={Icons.ADD_LINE} class="size-4"/>${busy.get() ? "Creating…" : "Create Project"}</button>
				</dialog-footer>
			</dialog-content>
		</dialog>;
	}

	function card(template:ProjectTemplate):Element {
		var button = <button id={"rayde-project-template-" + template.id} variant={Outline} class="rayde-project-template" disabled={locked()} onClick={_ -> selected.set(template.id)}>
			<div class="rayde-project-card-top">
				<icon document={icon(template.id)} class="rayde-project-template-icon"/>
				<text class="rayde-project-target">${template.target}</text>
				<icon document={Icons.CHECK_LINE} class="rayde-project-check"/>
			</div>
			<text class="rayde-project-template-name">${template.name}</text>
			<text class="rayde-project-template-description">${template.description}</text>
		</button>;
		var identity = ashui.css.Identity.of(button.tree, button.node.id);
		identity.setAttribute("data-kind", template.id);
		new Watch(() -> selected.get() == template.id, value -> identity.setAttribute("data-selected", value ? "" : null));
		return button;
	}

	function categoryButton(group:String):Element {
		var button = <button id={"rayde-project-category-" + group.toLowerCase()} variant={Ghost} size={Sm} disabled={locked()} onClick={_ -> chooseCategory(group)}>${group}</button>;
		var identity = ashui.css.Identity.of(button.tree, button.node.id);
		new Watch(() -> category.get() == group, value -> identity.setAttribute("data-selected", value ? "" : null));
		return button;
	}

	static function icon(id:String):ashui.svg.SvgDocument return switch id {
		case "hxml": Icons.HAXE;
		case "rayzor": rayzorIcon;
		case "haxelib": Icons.BOX_3_LINE;
		case "javascript": Icons.JAVASCRIPT_LINE;
		case "hashlink": Icons.TERMINAL_BOX_LINE;
		case "heaps": Icons.STACK_LINE;
		case "openfl": Icons.FLASHLIGHT_LINE;
		case "flixel": Icons.GAMEPAD_LINE;
		case "lime": Icons.WINDOW_LINE;
		case _: Icons.CODE_BOX_LINE;
	};

	function locked():Bool return busy.get() || browsing.get();
	function chooseCategory(value:String):Void {
		category.set(value);
		var templates = ProjectTemplates.matching(value);
		if (!Lambda.exists(templates, template -> template.id == selected.get())) selected.set(templates[0].id);
	}
	function close():Void { if (!locked()) props.opened.set(false); }
	function destination():String return haxe.io.Path.join([StringTools.trim(directory.get()), StringTools.trim(name.get())]);

	function browse():Void {
		if (locked()) return;
		error.set(""); browsing.set(true);
		#if ashui_window
		var app = ashui.app.WindowedApp.current;
		if (app != null && ashui.app.FileDialog.available()) {
			try cancelDialog = ashui.app.FileDialog.open(app, {title:"Choose a parent folder", folder:true, directory:directory.get()}, path -> {
				cancelDialog = null;
				if (gone) return;
				browsing.set(false);
				if (path != null) directory.set(path);
			}) catch (failure:Dynamic) { browsing.set(false); error.set(Std.string(failure)); }
			return;
		}
		#end
		jobs.submit("browse", {mode:"parent"});
		ashui.animation.AnimationScheduler.main.after(.03, poll);
	}

	function create():Void {
		if (locked()) return;
		var projectName = StringTools.trim(name.get()), parent = StringTools.trim(directory.get());
		if (!ProjectFile.validName(projectName)) { error.set("Start with a letter; use letters, numbers, hyphens or underscores (up to 64 characters)."); return; }
		if (parent == "") { error.set("Choose a location for your project."); return; }
		name.set(projectName); directory.set(parent); error.set(""); busy.set(true);
		jobs.submit("create", {mode:"new", kind:selected.get(), name:projectName, selected:parent});
		ashui.animation.AnimationScheduler.main.after(.03, poll);
	}

	function poll():Void {
		if (gone) return;
		for (result in jobs.poll()) {
			if (result.key == "browse") browsing.set(false) else busy.set(false);
			if (result.error != null) error.set(result.error);
			else if (result.value != null) {
				if (result.key == "browse") directory.set(result.value);
				else { props.opened.set(false); props.onCreate(result.value); return; }
			}
		}
		if (locked()) ashui.animation.AnimationScheduler.main.after(.05, poll);
	}
}
