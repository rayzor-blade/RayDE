package rayde.sync;

import ashui.reactive.Signal;

typedef ResourceSample = {
	available:Bool,
	?status:String,
	?sampledAt:Float,
	?cpuPercent:Float,
	?cpuLimit:Float,
	?memoryBytes:Float,
	?memoryLimitBytes:Float,
	?storageBytes:Float,
	?storageLimitBytes:Float,
	?uptimeSeconds:Float,
	?durationLimitSeconds:Float
};
typedef ResourceState = {loading:Bool, message:String, ?sample:ResourceSample};

/** Owns one asynchronous sample at a time. Only a visible panel asks for another. */
class ResourceUsage {
	public final state = Signal.make(({loading:true,message:""}:ResourceState));
	final request:Void->ash.Future<Dynamic>;
	final visible:Void->Bool;
	final now:Void->Float;
	var pending:Null<ash.Future<Dynamic>>;
	var next = 0.;
	var shown = false;
	var closed = false;
	var timer:Null<ashui.animation.AnimationScheduler.Timer>;
	public function new(request, visible, ?now:Void->Float) {
		this.request=request; this.visible=visible; this.now=now ?? haxe.Timer.stamp;
	}
	function cancelTimer():Void {if(timer!=null){timer.cancel();timer=null;}}
	public function refresh():Void {next=0;cancelTimer();ashui.core.Work.notify();}
	public function clear():Void {pending=null;next=0;cancelTimer();state.set({loading:true,message:""});}
	public function close():Void {closed=true;pending=null;cancelTimer();}
	public function frame():Void {
		if(closed)return;
		if(!visible()){pending=null;shown=false;next=0;cancelTimer();return;}
		if(!shown){shown=true;next=0;}
		if(pending!=null && pending.isReady()) {
			var done=pending;pending=null;next=now()+5;
			try {
				var sample:ResourceSample=done.await().result;
				if(sample==null)throw "The workspace returned no resource usage.";
				state.set({loading:false,message:sample.available ? "" : sample.status=="unprovisioned" ? "Usage is available in a provisioned cloud workspace." : "Live measurements are temporarily unavailable.",sample:sample});
				if(sample.status=="unprovisioned")next=Math.POSITIVE_INFINITY;
			} catch(error:Dynamic) {state.set({loading:false,message:rayde.workspace.PageHost.accountError(error)});}
		}
		if(pending==null && now()>=next) {
			var previous=state.get();state.set({loading:true,message:previous.message,sample:previous.sample});
			try pending=request() catch(error:Dynamic){state.set({loading:false,message:rayde.workspace.PageHost.accountError(error)});next=now()+5;}
		}
		if(timer==null && (pending!=null || next!=Math.POSITIVE_INFINITY))
			timer=ashui.animation.AnimationScheduler.main.after(pending!=null ? .05 : Math.max(.05,next-now()),() -> {timer=null;frame();});
	}
}
