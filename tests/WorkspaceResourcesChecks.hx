import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Owner;
import rayde.sync.ResourceUsage;
import rayde.ui.WorkspaceResources;
import rayde.ui.SyncPanel;

class WorkspaceResourcesChecks {
	static function check(ok:Bool,message:String):Void {if(!ok)throw message;}
	static function main():Void {
		var visible=false,time=0.,requests:Array<ash.Future<Dynamic>>=[];
		var usage=new ResourceUsage(() -> {var f=new ash.Future<Dynamic>();requests.push(f);return f;},()->visible,()->time);
		usage.frame();check(requests.length==0,"Hidden resources requested data");
		visible=true;usage.frame();check(requests.length==1 && usage.state.get().loading,"Opening must show loading before data arrives");
		time=20;usage.frame();check(requests.length==1,"Refresh overlapped a pending sample");
		requests[0].resolve({result:sample()});usage.frame();check(!usage.state.get().loading && usage.state.get().sample.memoryBytes==805306368,"Ready sample was not applied on the UI frame");
		time=24;usage.frame();check(requests.length==1,"Resources polled too soon");
		time=25;usage.frame();check(requests.length==2,"Visible resources did not refresh");
		visible=false;usage.frame();time=200;usage.frame();check(requests.length==2,"Hidden resources kept polling");
		requests[1].resolve({result:{available:true,memoryBytes:999}});
		visible=true;usage.frame();check(requests.length==3 && usage.state.get().sample.memoryBytes==805306368,"A hidden request replaced the last accepted sample");
		usage.clear();requests[2].resolve({result:sample()});usage.frame();check(requests.length==4 && usage.state.get().sample==null,"Account change accepted an older sample");
		requests[3].reject("Connection unavailable");usage.frame();check(!usage.state.get().loading && usage.state.get().message=="Connection unavailable" && usage.state.get().sample==null,"Failure must not present old measurements as live");
		usage.refresh();usage.frame();requests[4].resolve({result:{available:false,status:"unprovisioned"}});usage.frame();time=10000;usage.frame();check(requests.length==5,"Local demo should not poll for nonexistent compute");
		usage.close();usage.refresh();usage.frame();check(requests.length==5,"Disposed resources kept polling");
		for(dark in [true,false])for(width in [240,320])render(dark,width);
		for(dark in [true,false])panel(dark);
		for(dark in [true,false])browserPanel(dark);
		Sys.println("workspace resources: async loading, single-flight refresh, hidden/disposed polling, account fencing, unavailable states and narrow light/dark layout");
	}
	static function sample():ResourceSample return {available:true,cpuPercent:23.4,cpuLimit:2,memoryBytes:805306368,memoryLimitBytes:3221225472.,storageBytes:134217728,storageLimitBytes:1073741824,uptimeSeconds:640,durationLimitSeconds:3600};
	static function render(dark:Bool,width:Int):Void {
		ashui.theme.ThemeState.init(rayde.ui.Theming.bundle("restrained"),dark?Dark:Light);rayde.ui.Style.use();
		var tree=new LayoutTree(),stop:Void->Void=null,state=ashui.reactive.Signal.make(({loading:true,message:""}:ResourceState));
		var root=Owner.root(tree,cleanup->{stop=cleanup;return <div id="rayde" widthPercent={1} heightPercent={1}><div id="rayde-sync-panel" class="flex flex-col w-full h-full"><div class="rayde-sync-scroll">${new WorkspaceResources({state:state,onRefresh:()->{}})}</div></div></div>;});
		function settle():Void for(_ in 0...4){Offscreen.advance(.025);Css.setViewport(width,520);Css.update();tree.flush();tree.computeLayout(root.node,width,520);}
		settle();check(Css.query(tree,root.node.id,"#rayde-resources-cpu").length==0,"Loading must not show fabricated usage");
		state.set({loading:false,message:"",sample:sample()});settle();
		for(id in ["cpu","memory","storage","uptime"]){var nodes=Css.query(tree,root.node.id,"#rayde-resources-"+id);check(nodes.length==1,"Missing metric "+id);var b=tree.getScrolledBounds(new Node(nodes[0]));check(b.width>0 && b.x>=0 && b.x+b.width<=width && b.height>0,"Metric row clips sidebar: "+id+" "+Std.string(b));}
		Snapshot.capture("workspace-resources-"+(dark?"dark":"light")+"-"+width,tree,root.node,width,520);
		state.set({loading:false,message:"Workspace usage is temporarily unavailable."});settle();check(Css.query(tree,root.node.id,"#rayde-resources-message").length==1,"Unavailable state has no feedback");
		stop();tree.dispose();
	}
	static function panel(dark:Bool):Void {
		ashui.theme.ThemeState.init(rayde.ui.Theming.bundle("restrained"),dark?Dark:Light);rayde.ui.Style.use();
		var tree=new LayoutTree(),stop:Void->Void=null;
		var resources=ashui.reactive.Signal.make(({loading:true,message:""}:ResourceState));
		var state=ashui.reactive.Signal.make(rayde.sync.SyncState.Sync.empty(SignedOut));
		var saved=ashui.reactive.Signal.make((null:Null<rayde.ui.SyncPanel.SaveBack>));
		var fallback=ashui.reactive.Signal.make((null:Null<String>));
		var root=Owner.root(tree,cleanup->{stop=cleanup;return <div id="rayde" widthPercent={1} heightPercent={1}><for {message in [fallback.get()]}><sync-panel workspace="Pocket Studio" state={state} now={()->0.} saveBack={saved} resources={resources} onRefreshResources={()->{}} unavailableMessage={message}
			onPull={()->{}} onResolve={_->{}} onPick={(_,_) -> {}} onApply={()->{}} onDiff={_->{}} onSignIn={()->{}} onInitGit={()->{}} onSync={()->{}} onCancel={()->{}} onRetry={()->{}}
			onCopy={()->{}} onOpen={()->{}} onShare={()->{}} onPause={()->{}} onExport={()->{}} onExtend={()->{}} onDisconnect={()->{}} onDelete={()->{}} onExpiry={_->{}}/></for></div>;});
		function settle():Void for(_ in 0...4){Offscreen.advance(.025);Css.setViewport(320,900);Css.update();tree.flush();tree.computeLayout(root.node,320,900);}
		function has(selector:String):Bool return Css.query(tree,root.node.id,selector).length==1;
		try {
			settle();check(has("#rayde-sync-sign-in")&&has("#rayde-sync-phase")&&!has("#rayde-workspace-resources"),"Resource loading replaced the default Cloud Sync view");
			resources.set({loading:false,message:"Usage is available in a provisioned cloud workspace.",sample:{available:false,status:"unprovisioned"}});settle();
			check(has("#rayde-sync-sign-in")&&!has("#rayde-workspace-resources"),"An unprovisioned workspace replaced Cloud Sync with unavailable statistics");
			fallback.set("Cloud Sync starts from the desktop app. A synced workspace opens in the browser from its link.");settle();
			check(has("#rayde-sync-unavailable")&&!has("#rayde-workspace-resources"),"Resources suppressed the existing browser guidance");
			Snapshot.capture("cloud-sync-browser-default-"+(dark?"dark":"light"),tree,root.node,320,900);
			fallback.set(null);state.set(rayde.sync.SyncState.Sync.empty(Ready));resources.set({loading:false,message:"",sample:sample()});settle();
			check(has("#rayde-sync-start")&&has("#rayde-sync-phase")&&has("#rayde-workspace-resources"),"Provisioned statistics replaced sync controls");
			Snapshot.capture("cloud-sync-with-resources-"+(dark?"dark":"light"),tree,root.node,320,900);
			saved.set({generation:4,busy:false,message:"",failed:false,canMerge:false,conflicts:[]});settle();
			check(has("#rayde-sync-save")&&has("#rayde-sync-generation")&&has("#rayde-workspace-resources"),"Statistics replaced save-back controls");
		} catch(error:Dynamic){stop();tree.dispose();throw error;}
		stop();tree.dispose();
	}
	static function browserPanel(dark:Bool):Void {
		ashui.theme.ThemeState.init(rayde.ui.Theming.bundle("restrained"),dark?Dark:Light);rayde.ui.Style.use();
		var tree=new LayoutTree(),stop:Void->Void=null;
		var account=ashui.reactive.Signal.make(({checking:true}:rayde.sync.BrowserAccount.BrowserAccountState));
		var state=ashui.reactive.Signal.make(rayde.sync.SyncState.Sync.empty(SignedOut));
		var resources=ashui.reactive.Signal.make(({loading:false,message:"",sample:sample()}:ResourceState));
		var root=Owner.root(tree,cleanup->{stop=cleanup;return <div id="rayde" widthPercent={1} heightPercent={1} class="bg-background text-text-primary"><sync-panel workspace="project" state={state} now={()->0.} browserAccount={account} resources={resources}
			unavailableMessage="Cloud Sync starts from the desktop app. A synced workspace opens in the browser from its link."
			onPull={()->{}} onResolve={_->{}} onPick={(_,_) -> {}} onApply={()->{}} onDiff={_->{}} onSignIn={()->{}} onInitGit={()->{}} onSync={()->{}} onCancel={()->{}} onRetry={()->{}}
			onCopy={()->{}} onOpen={()->{}} onShare={()->{}} onPause={()->{}} onExport={()->{}} onExtend={()->{}} onDisconnect={()->{}} onDelete={()->{}} onExpiry={_->{}}/></div>;});
		function settle():Void for(_ in 0...4){Offscreen.advance(.025);Css.setViewport(320,900);Css.update();tree.flush();tree.computeLayout(root.node,320,900);}
		function has(selector:String):Bool return Css.query(tree,root.node.id,selector).length==1;
		function label():String {
			for(id in Css.query(tree,root.node.id,"#rayde-sync-account text")){var t=ashui.ui.Text.at(id);if(t!=null)return t.text();}
			return "";
		}
		try {
			settle();check(label()=="Checking account…"&&!has("#rayde-workspace-resources"),"Unverified account showed signed-out state with private usage");
			account.set({checking:false,login:"darmie"});settle();
			check(label()=="Signed in"&&!has("#rayde-sync-phase")&&has("#rayde-workspace-resources")&&has("#rayde-sync-unavailable"),"Browser account did not replace the stale native sign-in label");
			Snapshot.capture("cloud-sync-browser-signed-in-"+(dark?"dark":"light"),tree,root.node,320,900);
			account.set({checking:false});settle();check(label()=="Signed out"&&!has("#rayde-workspace-resources"),"Sign-out retained another account's usage");
			account.set({checking:false,message:"Account unavailable"});settle();check(label()=="Account unavailable"&&!has("#rayde-workspace-resources"),"Account failures appeared signed out or exposed old usage");
		} catch(error:Dynamic){stop();tree.dispose();throw error;}
		stop();tree.dispose();
	}
}
