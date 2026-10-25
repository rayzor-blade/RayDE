package rayde.ui;

import ashui.components.Button;
import ashui.components.Dialog;
import ashui.components.Icon;
import ashui.layout.Element;
import ashui.reactive.Computed;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.ui.Component;

typedef RepositoryPickerProps = {
	opened:Signal<Bool>, closed:Void->Void, ready:(String, Null<String>)->Void
};
private typedef Repository = {id:Float, fullName:String, description:Null<String>, branch:String};

/** Repository discovery and provisioning run outside the UI fiber. */
class RepositoryPicker extends Component<RepositoryPickerProps> {
	final account = Signal.make((null:Dynamic));
	final checked = Signal.make(false);
	final busy = Signal.make(false);
	final search = Signal.make("");
	final repositories = Signal.make(([]:Array<Repository>));
	final error = Signal.make("");
	final progress = Signal.make("");
	final jobs = new rayde.run.Worker<{op:String, params:Dynamic}, Dynamic>((request,_) -> rayde.workspace.PageHost.account(request.op,request.params));
	var cursor:Null<String>;
	final more = Signal.make(false);
	var installable = false;
	var workspace:Null<String>;
	var timer:Null<ashui.animation.AnimationScheduler.Timer>;
	var gone = false;
	var finished = false;
	var operation = "";

	function render():Element {
		request("account.status");
		Owner.onCleanup(() -> { gone = true; jobs.dispose(); if (timer != null) timer.cancel(); });
		var shown = Computed.make(() -> repositories.get().filter(repo -> repo.fullName.toLowerCase().indexOf(search.get().toLowerCase()) >= 0));
		return <dialog id="rayde-repository-picker" open={props.opened} onOpenChange={on -> if (!on) close()}>
			<dialog-content id="rayde-repository-dialog" size={Lg}>
				<dialog-header><div class="flex items-center gap-3"><icon document={Icons.GITHUB_FILL} class="size-6"/><dialog-title>Open repository</dialog-title></div>
					<dialog-description>Code in a remote workspace connected to your GitHub repository.</dialog-description></dialog-header>
				<if {!checked.get()}><text class="text-sm text-text-secondary py-6">Connecting to the workspace service…</text>
				<else><if {account.get() == null}>
					<div class="flex flex-col gap-4 py-5"><text class="text-sm text-text-secondary">Sign in to choose a repository. You control which repositories RayDE can access.</text>
						<button id="rayde-repository-signin" disabled={busy.get()} onClick={_ -> request("account.signin")}><icon document={Icons.GITHUB_FILL} class="size-4"/>Continue with GitHub</button></div>
				<else>
					<div class="flex items-center gap-2"><text class="text-xs text-text-secondary flex-1">${"Signed in as " + account.get().login}</text>
						<button id="rayde-repository-signout" variant={Ghost} size={Sm} disabled={busy.get()} onClick={_ -> request("account.signout")}>Sign out</button></div>
					<input id="rayde-repository-search" class="w-full" value={search} placeholder="Find a repository…" disabled={workspace != null}/>
					<div height={300} class="flex flex-col min-h-0">
						<for {entries in [shown.get()]}>${rows(entries)}</for>
					</div>
					<div class="flex items-center justify-between gap-2">
						<if {installable}><button id="rayde-repository-install" variant={Ghost} size={Sm} disabled={busy.get()} onClick={_ -> request("account.install")}>Manage repository access</button></if>
						<if {more.get()}><button id="rayde-repository-more" variant={Outline} size={Sm} disabled={busy.get()} onClick={_ -> request("account.repositories",{cursor:cursor})}>Load more</button></if>
					</div>
				</if></if>
				<if {busy.get() || progress.get() != ""}><div class="flex items-center gap-2"><icon document={Icons.LOADER_4_LINE} class="size-4 animate-spin text-accent"/><text id="rayde-repository-progress" class="text-sm text-text-secondary">${progress.get() == "" ? "Loading…" : progress.get()}</text></div></if>
				<if {error.get() != ""}><text id="rayde-repository-error" class="text-sm text-error">${error.get()}</text><button id="rayde-repository-retry" variant={Outline} onClick={_ -> { workspace = null; request("account.status"); }}>Try again</button></if>
				<dialog-footer><button id="rayde-repository-cancel" variant={Outline} onClick={_ -> close()}>Cancel</button></dialog-footer>
			</dialog-content>
		</dialog>;
	}

	function rows(entries:Array<Repository>):Element {
		var box = <div id="rayde-repositories" class="flex flex-col overflow-auto" height={300}/>;
		var scroll = ashui.input.Scroll.attach(box.node,false,true);
		var first = Computed.make(() -> Std.int(Math.max(0,Math.floor(scroll.y.get()/60)-2)));
		var end = Computed.make(() -> Std.int(Math.min(entries.length,first.get()+10)));
		box.appendChild(<div height={Computed.make(() -> first.get()*60.)} flexShrink={0}/>);
		box.appendChild(<for {repo in Computed.make(() -> entries.slice(first.get(),end.get()))}>${row(repo)}</for>);
		box.appendChild(<div height={Computed.make(() -> (entries.length-end.get())*60.)} flexShrink={0}/>);
		if (entries.length == 0) box.appendChild(<text class="text-sm text-text-secondary p-3">No repositories here. Check your repository access or load another page.</text>);
		return box;
	}

	function row(repo:Repository):Element
		return <button id={"rayde-repository-" + Std.string(repo.id)} variant={Ghost} class="rayde-repository-row" disabled={busy.get()} onClick={_ -> {
			progress.set("Preparing " + repo.fullName + "…"); request("account.open",{repository:repo.id});
		}}><icon document={Icons.GIT_REPOSITORY_LINE} class="size-5 shrink-0 text-accent"/>
			<div class="flex flex-col flex-1 min-w-0 gap-1"><text class="text-sm" wrap={false}>${repo.fullName}</text><text class="text-xs text-text-secondary" wrap={false}>${repo.description ?? repo.branch}</text></div>
			<if {Reflect.field(repo,"private") == true}><icon document={Icons.LOCK_LINE} class="size-4 shrink-0 text-text-tertiary"/></if>
		</button>;

	function request(op:String, ?params:Dynamic):Void {
		operation = op; busy.set(true); error.set(""); jobs.submit("account",{op:op,params:params ?? {}});
		if (timer == null) timer = ashui.animation.AnimationScheduler.main.after(.02,poll);
	}
	function poll():Void {
		timer = null; if (gone) return;
		for (result in jobs.poll()) {
			busy.set(false);
			if (result.error != null) { checked.set(true); error.set(result.error); progress.set(""); workspace = null; continue; }
			var value:Dynamic = result.value;
			switch operation {
				case "account.status":
					account.set(value.user); checked.set(true); installable = value.installable == true;
					if (value.user != null) { repositories.set([]); cursor = null; request("account.repositories"); }
				case "account.repositories":
					var all = repositories.get().copy(), batch:Array<Repository> = value.repositories;
					for (repo in batch) if (!Lambda.exists(all,known -> known.id == repo.id)) all.push(repo);
					all.sort((a,b) -> Reflect.compare(a.fullName.toLowerCase(),b.fullName.toLowerCase()));
					repositories.set(all); cursor = value.cursor; more.set(cursor != null);
				case "account.open", "account.workspace":
					workspace = value.id;
					if (value.status == "ready") { progress.set(""); props.ready(value.id,value.project); close(); }
					else if (value.status == "failed") { workspace = null; progress.set(""); error.set(value.message ?? "The workspace could not be prepared."); }
				default:
			}
		}
		if (gone || finished) return;
		if (busy.get()) timer = ashui.animation.AnimationScheduler.main.after(.03,poll);
		else if (workspace != null) timer = ashui.animation.AnimationScheduler.main.after(.5,() -> { timer = null; if (!gone) request("account.workspace",{workspace:workspace}); });
	}
	function close():Void {
		if (finished || gone) return;
		finished = true; props.closed(); props.opened.set(false);
	}
}
