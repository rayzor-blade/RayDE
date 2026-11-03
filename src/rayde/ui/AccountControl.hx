package rayde.ui;

import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.workspace.PageHost;

typedef AccountControlProps = {
	beforeSignOut:(Void->Void)->Void,
	say:String->Void,
	?request:(String, Dynamic)->ash.Future<Dynamic>,
	?subscribe:(Dynamic->Void)->(Void->Void)
};

/** One initial account check and notifications keep the header current without idle polling. */
class AccountControl extends Component<AccountControlProps> {
	final user = Signal.make((null:Dynamic));
	final busy = Signal.make(true);
	final failure = Signal.make("");
	var pending:Null<ash.Future<Dynamic>>;
	var operation = "";
	var timer:Null<ashui.animation.AnimationScheduler.Timer>;
	var gone = false;

	function render():Element {
		var stop = props.subscribe != null ? props.subscribe(changed) : PageHost.bridge == null ? () -> {} : PageHost.bridge.subscribe(changed);
		Owner.onCleanup(() -> {
			gone = true; stop(); if (timer != null) timer.cancel();
			if (operation == "account.signin" && pending != null) {
				if (props.request == null) PageHost.requestAccount("account.cancel-signin"); else props.request("account.cancel-signin", {});
			}
			pending = null;
		});
		timer = ashui.animation.AnimationScheduler.main.after(.016, () -> { timer = null; if (!gone) request("account.status"); });
		return <div id="rayde-account" class="rayde-header-account flex items-center" onPointerDown={e -> e.stopPropagation()}>
			<if {user.get() != null}><icon document={Icons.GITHUB_FILL} class="size-4 shrink-0 text-text-secondary"/><text id="rayde-account-name" class="rayde-account-name text-xs">${user.get() == null ? "" : user.get().login}</text></if>
			<tooltip label={busy.get() ? operation == "account.signout" ? "Signing out…" : operation == "account.signin" ? "Complete sign-in in the GitHub window…" : "Checking GitHub account…" : failure.get() != "" ? failure.get() + " — click to retry" : user.get() == null ? "Sign in with GitHub" : "Sign out of GitHub (" + user.get().login + ")"} side="bottom">
				<button id="rayde-account-action" variant={Outline} size={Sm} class="rayde-account-action" disabled={busy.get()} onClick={_ -> activate()}>
					<if {busy.get()}><icon document={Icons.LOADER_4_LINE} class="size-4 animate-spin"/><else><icon document={failure.get() != "" ? Icons.RESTART_LINE : user.get() == null ? Icons.GITHUB_FILL : Icons.LOGOUT_BOX_R_LINE} class="size-4"/></if>
					<if {user.get() == null}><text class="rayde-account-action-label">${failure.get() != "" ? "Retry" : "Sign in"}</text></if>
				</button>
			</tooltip>
		</div>;
	}
	function changed(event:Dynamic):Void {
		if (gone || event.ev != null && event.ev != "account.changed") return;
		user.set(event.user); failure.set("");
	}
	function activate():Void {
		if (busy.get()) return;
		if (failure.get() != "") { request("account.status"); return; }
		if (user.get() == null) request("account.signin");
		else props.beforeSignOut(() -> { if (!gone && !busy.get()) request("account.signout"); });
	}
	function request(op:String):Void {
		operation = op; busy.set(true); failure.set("");
		pending = props.request == null ? PageHost.requestAccount(op) : props.request(op, {});
		schedule();
	}
	function schedule():Void { if (timer == null) timer = ashui.animation.AnimationScheduler.main.after(.03, poll); }
	function poll():Void {
		timer = null; if (gone || pending == null) return;
		if (!pending.isReady()) { schedule(); return; }
		var reply = pending; pending = null; busy.set(false);
		try {
			var result:Dynamic = reply.await().result;
			if (result == null) throw "The account service returned an invalid response.";
			if (operation == "account.signout") user.set(null);
			else user.set(result.user);
		} catch (error:Dynamic) { var message = PageHost.accountError(error); failure.set(message); props.say(message); }
	}
}
