package rayde.run;

import rayde.workspace.session.SessionClient;
import ashui.reactive.Signal;

private typedef Build = {client:SessionClient, compiler:String, args:Array<String>, cwd:String, progress:BuildProgress, force:Bool, family:String, manifest:Null<String>};
private typedef Configuration = {compiler:String,args:Array<String>,cwd:String,family:String,manifest:Null<String>};
typedef AppArtifact = rayde.run.AppPreviewCompiler.PreviewArtifact;

/** One supervised browser build per window. Compiler work and output readers stay off the UI thread. */
class AppPreviewBuild {
	public final artifact = Signal.make((null:Null<AppArtifact>));
	public final state = Signal.make("idle");
	public final title = Signal.make("");
	public final error = Signal.make("");
	public final output = Signal.make("");
	public final phase = Signal.make("");
	public final elapsed = Signal.make(0);
	final client:SessionClient;
	final unsubscribe:Void->Void;
	final publish:Null<String->Void>;
	var progress:Null<BuildProgress>;
	var started = 0.;
	var seen = -1;
	final worker = new Worker<Build,{artifact:AppArtifact,output:String}>(build, () -> ashui.core.Work.notify());
	var timer:Null<ashui.animation.AnimationScheduler.Timer>;
	var gone = false;
	var reconnecting = false;
	var contextLost = false;
	var configuration:Null<Configuration>;
	public function new(client:SessionClient, ?publish:String->Void) {
		this.client=client;
		this.publish=publish;
		unsubscribe=client.subscribe(event -> {
            if(gone)return;
            if(event.ev=="preview.title"){
                var current=artifact.get();
                if(current!=null && event.preview==current.preview && Std.isOfType(event.title,String))title.set((event.title:String).substr(0,256));
                return;
            }
			if(event.ev=="session.connected") {
				if(reconnecting && configuration!=null && !contextLost) {
					var saved=configuration;reconnecting=false;
					start(saved.compiler,saved.args,saved.cwd,false,saved.family,saved.manifest);
				}
				return;
			}
			if(event.ev!="session.disconnected")return;
			if(event.code=="workspace-changed") {
				contextLost=true;reconnecting=false;configuration=null;worker.cancel("app");
				if(timer!=null)timer.cancel();
				artifact.set(null);state.set("failed");error.set(event.message ?? "The workspace changed. Reopen it before previewing.");return;
			}
			if(state.get()!="building" && state.get()!="ready" && !reconnecting)return;
			reconnecting=true;worker.cancel("app");if(timer!=null)timer.cancel();
			state.set("reconnecting");error.set("");phase.set("Waiting for workspace connection");
			if(progress!=null){progress.append("Workspace disconnected; the preview will recover after reconnecting.\n");output.set(progress.snapshot().output);if(publish!=null)publish(output.get());}
		});
	}
	public function start(compiler:String,args:Array<String>,cwd:String,force=false,family="haxe",?manifest:String):Void {
		if (gone || contextLost || state.get() == "building") return;
		if(timer!=null)timer.cancel();
		reconnecting=false;configuration={compiler:compiler,args:args.copy(),cwd:cwd,family:family,manifest:manifest};
		state.set("building");if(artifact.get()==null)title.set("");error.set("");output.set("");phase.set("Preparing preview");elapsed.set(0);
		started=haxe.Timer.stamp();seen=-1;progress=new BuildProgress();
		worker.submit("app",{client:client,compiler:compiler,args:args.copy(),cwd:cwd,progress:progress,force:force,family:family,manifest:manifest});poll();
	}
	public function stop():Void {
		if(state.get()!="building" && state.get()!="reconnecting")return;
		reconnecting=false;
		worker.cancel("app");state.set("cancelled");phase.set("Build cancelled");
		progress.append("Preview build cancelled.\n");
	}
	function poll():Void {
		if (gone) return;
		if(progress!=null){
			var update=progress.snapshot();
			if(update.revision!=seen){
				seen=update.revision;output.set(update.output);
				if(state.get()=="building")phase.set(update.phase);
				if(publish!=null)publish(update.output);
			}
		}
		if(state.get()=="building")elapsed.set(Std.int(haxe.Timer.stamp()-started));
		for (result in worker.poll()) {
			if (result.error != null) {error.set(result.error);state.set("failed");}
			else {
				var previous=artifact.get();artifact.set(result.value.artifact);output.set(result.value.output);state.set("ready");
				if (previous!=null && !(previous.cached==true && previous.preview==result.value.artifact.preview)) release(previous);
			}
		}
		if (worker.busy()) timer=ashui.animation.AnimationScheduler.main.after(.05,poll);
	}
	function release(value:AppArtifact):Void {
		if (value.cached == true) { client.requestAsync("page.demo-close",{preview:value.preview}); return; }
		client.requestAsync("preview.close",{preview:value.preview}).then(_ -> client.requestAsync("preview.discard",{path:value.path}),_ -> {});
	}
	public function dispose():Void {
		gone=true;reconnecting=false;configuration=null;unsubscribe();if(timer!=null)timer.cancel();worker.dispose();
		var previous=artifact.get();if(previous!=null)release(previous);artifact.set(null);
	}
	public static function compilerArgs(args:Array<String>,support:String,output:String):Array<String>
        return RunPlan.compilerArgs(args,"hl",output,true,support);
	static function build(value:Build,cancelled:Void->Bool):{artifact:AppArtifact,output:String}
		return AppPreviewCompiler.build(value,cancelled);
}
