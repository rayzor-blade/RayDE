package rayde.sync;

import ashui.reactive.Signal;

typedef BrowserAccountState = {checking:Bool, ?login:String, ?message:String};

/** Reads the browser account once, then follows its notifications. Completions are applied on the UI frame. */
class BrowserAccount {
	public final state = Signal.make(({checking:true}:BrowserAccountState));
	var pending:Null<ash.Future<Dynamic>>;
	var stop:Void->Void;
	var timer:Null<ashui.animation.AnimationScheduler.Timer>;
	var closed = false;

	public function new(request:Void->ash.Future<Dynamic>, subscribe:(Dynamic->Void)->(Void->Void), changed:Void->Void) {
		stop = subscribe(event -> {
			if (closed || event.ev != "account.changed") return;
			pending = null;
			apply(event.user);
			changed();
		});
		try pending = request() catch (error:Dynamic) state.set({checking:false,message:rayde.workspace.PageHost.accountError(error)});
		schedule();
	}
	function apply(user:Dynamic):Void state.set({checking:false,login:user == null ? null : user.login});
	function schedule():Void {
		if (!closed && pending != null && timer == null) timer = ashui.animation.AnimationScheduler.main.after(.03, () -> {timer=null;frame();});
	}
	public function frame():Void {
		if (closed) return;
		if (pending != null && pending.isReady()) {
			var done = pending; pending = null;
			try {
				var result = done.await().result;
				if (result == null) throw "The account service returned no account status.";
				apply(result.user);
			} catch (error:Dynamic) state.set({checking:false,message:rayde.workspace.PageHost.accountError(error)});
		}
		if (pending == null && timer != null) {timer.cancel();timer=null;}
		schedule();
	}
	public function signedIn():Bool return state.get().login != null;
	public function close():Void {
		closed=true;pending=null;stop();if(timer!=null){timer.cancel();timer=null;}
	}
}
