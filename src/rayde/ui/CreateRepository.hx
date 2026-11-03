package rayde.ui;

import ashui.components.Button;
import ashui.components.Dialog;
import ashui.components.Icon;
import ashui.components.ToggleSwitch;
import ashui.layout.Element;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.project.ProjectFile;
import rayde.project.ProjectTemplates;
import rayde.project.ProjectTemplates.ProjectTemplate;
import rayde.workspace.PageHost;

typedef CreateRepositoryProps = {
	opened:Signal<Bool>, template:ProjectTemplate, name:String,
	back:Void->Void, ready:(String, Null<String>)->Void
};
private typedef Creation = {key:String, template:ProjectTemplate, name:String, description:String, privateRepo:Bool};

/** Scaffolding runs in a worker; the dialog only consumes completed account requests. */
class CreateRepository extends Component<CreateRepositoryProps> {
	final visible = Signal.make(false);
	final name = Signal.make("");
	final description = Signal.make("");
	final privateRepo = Signal.make(true);
	final checked = Signal.make(false);
	final account = Signal.make((null:Dynamic));
	final busy = Signal.make(false);
	final frozen = Signal.make(false);
	final error = Signal.make("");
	final progress = Signal.make("");
	final repository = Signal.make((null:Dynamic));
	final seeded = Signal.make(false);
	final jobs = new rayde.run.Worker<Creation, Dynamic>(create);
	final key = haxe.crypto.Sha256.encode(Sys.time() + ":" + Std.random(0x3fffffff) + ":" + Std.random(0x3fffffff));
	var pending:Null<ash.Future<Dynamic>>;
	var operation = "";
	var workspace:Null<String>;
	var timer:Null<ashui.animation.AnimationScheduler.Timer>;
	var gone = false;

	function render():Element {
		name.set(props.name);
		Owner.onCleanup(() -> {
			gone = true;
			if (operation == "account.signin") PageHost.requestAccount("account.cancel-signin");
			pending = null; if (timer != null) timer.cancel(); jobs.dispose();
		});
		timer = ashui.animation.AnimationScheduler.main.after(0, () -> {
			timer = null; if (gone) return; visible.set(true);
			timer = ashui.animation.AnimationScheduler.main.after(.016, () -> { timer = null; if (!gone) request("account.status"); });
		});
		return <dialog id="rayde-create-repository" open={visible} onOpenChange={on -> if (!on) close()}>
			<dialog-content id="rayde-create-repository-dialog" size={Lg} onCancel={e -> if (locked()) e.preventDefault()}>
				<dialog-header><dialog-title>Create a repository</dialog-title><dialog-description>Your selected starter becomes a new GitHub repository and remote workspace.</dialog-description></dialog-header>
				<div class="rayde-repository-starter"><project-logo template={props.template}/><div class="flex flex-col gap-1 min-w-0"><text class="text-sm font-semibold">${props.template.name}</text><text class="text-xs text-text-secondary">${props.template.description}</text></div></div>
				<div class="flex flex-col gap-2"><label for="rayde-repository-name">Repository name</label><input id="rayde-repository-name" value={name} maxlength={64} disabled={frozen.get()} placeholder="my-project"/></div>
				<div class="flex flex-col gap-2"><label for="rayde-repository-description">Description (optional)</label><input id="rayde-repository-description" value={description} maxlength={350} disabled={frozen.get()}/></div>
				<div class="flex items-center gap-3"><icon document={Icons.LOCK_LINE} class="size-4 text-text-secondary"/><div class="flex flex-col flex-1 gap-1"><text class="text-sm">Private repository</text><text class="text-xs text-text-secondary">${privateRepo.get() ? "Only people you grant access can see it." : "Anyone can view this repository on GitHub."}</text></div><toggle-switch id="rayde-repository-private" checked={privateRepo.get()} disabled={frozen.get()} onChange={privateRepo.set}/></div>
				<if {!checked.get()}><text class="text-sm text-text-secondary">Connecting to the workspace service…</text><else><if {account.get() == null}>
					<button id="rayde-create-repository-signin" disabled={busy.get()} onClick={_ -> request("account.signin")}><icon document={Icons.GITHUB_FILL} class="size-4"/>Continue with GitHub</button>
				<else><text class="text-xs text-text-secondary">${"Create under " + account.get().login}</text></if></if>
				<if {repository.get() != null}><text id="rayde-created-repository" class="text-sm text-success">${"Repository created: " + repository.get().fullName}</text></if>
				<if {busy.get()}><div class="flex items-center gap-2"><icon document={Icons.LOADER_4_LINE} class="size-4 animate-spin text-accent"/><text id="rayde-create-repository-progress" class="text-sm text-text-secondary">${progress.get()}</text></div></if>
				<if {error.get() != ""}><text id="rayde-create-repository-error" class="text-sm text-error">${error.get()}</text><if {!checked.get() || account.get() == null}><button variant={Outline} disabled={busy.get()} onClick={_ -> request("account.status")}>Check connection</button></if></if>
				<dialog-footer><button id="rayde-create-repository-back" variant={Ghost} disabled={busy.get() || frozen.get()} onClick={_ -> props.back()}>Back</button><button id="rayde-create-repository-cancel" variant={Outline} disabled={locked()} onClick={_ -> close()}>Cancel</button><button id="rayde-create-repository-submit" disabled={busy.get() || account.get() == null} onClick={_ -> submit()}><icon document={Icons.GITHUB_FILL} class="size-4"/>${seeded.get() ? "Open Workspace" : frozen.get() ? "Retry" : "Create Repository"}</button></dialog-footer>
			</dialog-content>
		</dialog>;
	}

	function locked():Bool return busy.get() && operation != "account.signin" && operation != "account.status";
	function close():Void { if (!locked()) props.opened.set(false); }
	function submit():Void {
		if (busy.get() || account.get() == null) return;
		if (seeded.get()) { request("account.open", {repository:repository.get().id}); return; }
		var title = StringTools.trim(name.get());
		if (!ProjectFile.validName(title)) { error.set("Start with a letter; use letters, numbers, hyphens or underscores (up to 64 characters)."); return; }
		name.set(title); frozen.set(true); busy.set(true); operation = "create"; error.set(""); progress.set("Creating repository and adding the starter…");
		jobs.submit("create", {key:key, template:props.template, name:title, description:description.get(), privateRepo:privateRepo.get()});
		schedule();
	}
	static function create(job:Creation, cancelled:Void->Bool):Dynamic {
		var scaffold = job.template.scaffold == null ? ProjectTemplates.scaffold(job.template.id, job.name) : ProjectTemplates.instantiate(job.template.scaffold, job.name);
		ProjectTemplates.validate(scaffold);
		var paths = [for (path in scaffold.files.keys()) path]; paths.sort(Reflect.compare);
		if (cancelled()) throw "Project creation cancelled.";
		var project:Dynamic = {name:job.name, description:job.description, entry:scaffold.entry,
			files:[for (path in paths) {path:path, text:scaffold.files.get(path)}]};
		Reflect.setField(project, "private", job.privateRepo);
		return PageHost.account("account.create", {key:job.key, project:project});
	}
	function request(op:String, ?params:Dynamic):Void {
		operation = op; busy.set(true); error.set("");
		progress.set(op == "account.signin" ? "Complete sign-in in the GitHub window…" : op == "account.status" ? "Connecting…" : "Preparing the workspace…");
		pending = PageHost.requestAccount(op, params); schedule();
	}
	function schedule():Void { if (timer == null) timer = ashui.animation.AnimationScheduler.main.after(.03, poll); }
	function poll():Void {
		timer = null; if (gone) return;
		for (result in jobs.poll()) {
			busy.set(false);
			if (result.error != null) error.set(result.error);
			else {
				var value = result.value;
				repository.set(value.repository);
				if (value.status == "ready") { seeded.set(true); request("account.open", {repository:value.repository.id}); }
				else error.set(value.message ?? "The repository was created, but its starter is incomplete. Retry to continue.");
			}
		}
		if (pending != null && pending.isReady()) {
			var reply = pending; pending = null; busy.set(false);
			try {
				var value:Dynamic = reply.await().result;
				if (value == null) throw "The account service returned an invalid response.";
				switch operation {
					case "account.status", "account.signin": account.set(value.user); checked.set(true);
					case "account.open", "account.workspace":
						workspace = value.id;
						if (value.status == "ready") { props.ready(value.id, value.project); return; }
						if (value.status == "failed") { workspace = null; error.set(value.message ?? "The workspace could not be prepared. You can retry opening it."); }
					default:
				}
			} catch (failure:Dynamic) { checked.set(true); workspace = null; error.set(PageHost.accountError(failure)); }
		}
		if (gone) return;
		if (busy.get()) schedule();
		else if (workspace != null) {
			busy.set(true);
			timer = ashui.animation.AnimationScheduler.main.after(.5, () -> { timer = null; if (!gone) request("account.workspace", {workspace:workspace}); });
		}
	}
}
