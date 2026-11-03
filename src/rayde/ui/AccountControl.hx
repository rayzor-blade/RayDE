package rayde.ui;

import ashui.components.Button;
import ashui.components.DropdownMenu;
import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Owner;
import ashui.reactive.Computed;
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
	final cancelling = Signal.make(false);
	final menu = Signal.make(false);
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
		var root = <div id="rayde-account" class="rayde-header-account flex items-center" onPointerDown={e -> e.stopPropagation()}>
			<if {user.get() != null}>
				<dropdown-menu id="rayde-account-dropdown" open={menu}>
					<dropdown-menu-trigger id="rayde-account-trigger" variant={Outline} size={Sm} class="rayde-account-action">
						<if {busy.get()}><icon document={Icons.LOADER_4_LINE} class="size-4 animate-spin"/><else><icon document={Icons.GITHUB_FILL} class="size-4"/></if>
						<text id="rayde-account-name" class="rayde-account-name">${user.get() == null ? "" : user.get().login}</text>
					</dropdown-menu-trigger>
					<dropdown-menu-content id="rayde-account-menu">
						<if {failure.get() != ""}><dropdown-menu-item id="rayde-account-retry" disabled={busy.get()} onSelect={() -> request("account.status")}><icon document={Icons.RESTART_LINE} class="size-4"/>Retry connection</dropdown-menu-item><dropdown-menu-separator/></if>
						<dropdown-menu-item id="rayde-account-manage" disabled={busy.get()} onSelect={() -> request("account.manage-access")}><icon document={Icons.SETTINGS_3_LINE} class="size-4"/>Manage access</dropdown-menu-item>
						<dropdown-menu-item id="rayde-account-signout" disabled={busy.get()} onSelect={signOut}><icon document={Icons.LOGOUT_BOX_R_LINE} class="size-4"/>Sign out</dropdown-menu-item>
					</dropdown-menu-content>
				</dropdown-menu>
			<else>
				${signInControl()}
			</if>
		</div>;
		return root;
	}
	function signInControl():Element {
		var root = <tooltip label={label()} side="bottom">
				<button id="rayde-account-action" variant={Outline} size={Sm} class="rayde-account-action" disabled={busy.get() && (operation != "account.signin" || cancelling.get())} onClick={_ -> activate()}>
					<if {busy.get() && operation == "account.signin" && !cancelling.get()}><icon document={Icons.CLOSE_LINE} class="size-4"/><else><if {busy.get()}><icon document={Icons.LOADER_4_LINE} class="size-4 animate-spin"/><else><icon document={failure.get() != "" ? Icons.RESTART_LINE : user.get() == null ? Icons.GITHUB_FILL : Icons.LOGOUT_BOX_R_LINE} class="size-4"/></if></if>
					<if {user.get() == null}><text class="rayde-account-action-label">${busy.get() && operation == "account.signin" ? "Cancel" : failure.get() != "" ? "Retry" : "Sign in"}</text></if>
				</button>
			</tooltip>;
		for (node in ashui.css.Css.query(root.tree,root.node.id,"#rayde-account-action"))
			ashui.css.Identity.of(root.tree,node).bindAttribute("aria-label", Computed.make(label));
		return root;
	}
	function label():String {
		if (busy.get()) return operation == "account.signout" ? "Signing out…" : operation == "account.signin" ? cancelling.get() ? "Cancelling sign-in…" : "Cancel GitHub sign-in" : "Checking GitHub account…";
		return failure.get() != "" ? failure.get() + " — click to retry" : user.get() == null ? "Sign in with GitHub" : "Sign out of GitHub (" + user.get().login + ")";
	}
	function changed(event:Dynamic):Void {
		if (gone || event.ev != null && event.ev != "account.changed") return;
		user.set(event.user); failure.set("");
	}
	function signOut():Void {
		if (!busy.get()) props.beforeSignOut(() -> { if (!gone && !busy.get()) request("account.signout"); });
	}
	function activate():Void {
		if (busy.get()) {
			if (operation == "account.signin" && !cancelling.get()) {
				cancelling.set(true);
				if (props.request == null) PageHost.requestAccount("account.cancel-signin"); else props.request("account.cancel-signin", {});
			}
			return;
		}
		if (failure.get() != "") { request("account.status"); return; }
		if (user.get() == null) request("account.signin");
	}
	function request(op:String):Void {
		menu.set(false); operation = op; cancelling.set(false); busy.set(true); failure.set("");
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
			else if (operation == "account.status" || operation == "account.signin") user.set(result.user);
		} catch (error:Dynamic) { if (!cancelling.get()) { var message = PageHost.accountError(error); failure.set(message); props.say(message); } }
	}
}
