package rayde.run;

import rayde.workspace.Program;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.SessionLauncher;
import ashui.reactive.Signal;

private typedef Build = {client:SessionClient, compiler:String, args:Array<String>, cwd:String, progress:BuildProgress, force:Bool, family:String, manifest:Null<String>};
typedef AppArtifact = {preview:String, url:String, path:String, ?arguments:Array<String>};

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
	public function new(client:SessionClient, ?publish:String->Void) {
		this.client=client;
		this.publish=publish;
		unsubscribe=client.subscribe(event -> {
            if(event.ev=="preview.title" && !gone && state.get()=="ready"){
                var current=artifact.get();
                if(current!=null && event.preview==current.preview && Std.isOfType(event.title,String))title.set((event.title:String).substr(0,256));
                return;
            }
			if(event.ev!="session.disconnected" || gone)return;
			worker.cancel("app");artifact.set(null);state.set("failed");error.set("The session disconnected. Rebuild the preview after reconnecting.");
			if(progress!=null)progress.append(error.get()+"\n");
		});
	}
	public function start(compiler:String,args:Array<String>,cwd:String,force=false,family="haxe",?manifest:String):Void {
		if (state.get() == "building") return;
		if(timer!=null)timer.cancel();
		state.set("building");title.set("");error.set("");output.set("");phase.set("Preparing preview");elapsed.set(0);
		started=haxe.Timer.stamp();seen=-1;progress=new BuildProgress();
		worker.submit("app",{client:client,compiler:compiler,args:args.copy(),cwd:cwd,progress:progress,force:force,family:family,manifest:manifest});poll();
	}
	public function stop():Void {
		if(state.get()!="building")return;
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
				if (previous!=null) release(previous);
			}
		}
		if (worker.busy()) timer=ashui.animation.AnimationScheduler.main.after(.05,poll);
	}
	function release(value:AppArtifact):Void {
		if(!client.isOnline())return;
		client.requestAsync("preview.close",{preview:value.preview}).then(_ -> client.requestAsync("preview.discard",{path:value.path}),_ -> {});
	}
	public function dispose():Void {
		gone=true;unsubscribe();if(timer!=null)timer.cancel();worker.dispose();
		var previous=artifact.get();if(previous!=null)release(previous);artifact.set(null);
	}
	public static function compilerArgs(args:Array<String>,support:String,output:String):Array<String>
        return RunPlan.compilerArgs(args,"hl",output,true,support);
	static function build(value:Build,cancelled:Void->Bool):{artifact:AppArtifact,output:String} {
		var progress=value.progress;
		progress.stage("Preparing preview");
		var epoch=value.client.connectionEpoch();
		var isCancelled=() -> cancelled() || !value.client.isOnline() || value.client.connectionEpoch()!=epoch;
		var prepared:Dynamic=null,opened:Dynamic=null;
		function run(command:String,args:Array<String>,?env:Dynamic):Void {
			if(isCancelled())throw "Preview build cancelled.";
			progress.append(command+" "+args.join(" ")+"\n");
			var launcher:SessionLauncher=cast rayde.workspace.Procs.current;
			var process:Program=launcher.startConfigured(command,args,value.cwd,env).await();
			var readers=new sys.thread.Lock();
			for(input in [process.stdout,process.stderr])sys.thread.Thread.create(() -> {
				try {var bytes=haxe.io.Bytes.alloc(8192);while(true){var size=input.readBytes(bytes,0,bytes.length);if(size==0)break;progress.append(bytes.sub(0,size).toString());}}catch(_:haxe.io.Eof){}catch(e:Dynamic){progress.append(Std.string(e));}
				readers.release();
			});
			var end=haxe.Timer.stamp()+180.,code:Null<Int>=null;
			try {
				process.stdin.close();
				while((code=process.exitCode(false))==null){
					if(isCancelled()||haxe.Timer.stamp()>end)throw "Preview build cancelled or timed out.";
					Sys.sleep(.03);
				}
				readers.wait(2);readers.wait(2);
				if(code!=0)throw "Preview build failed. Open Build output for details.";
			} catch(error:Dynamic){try process.kill() catch(_:Dynamic){};process.close();throw error;}
			process.close();
		}
		function cache(stage:String):Void {
			if(isCancelled())throw "Preview build cancelled.";
			progress.stage(stage=="bytecode" ? "Caching bytecode" : "Caching preview");
			try {
				var result=value.client.request("preview.cache",{path:prepared.path,stage:stage});
				if(result.cacheNote!=null && result.cacheNote!="")progress.append("Cache: "+result.cacheNote+"\n");
			} catch(error:Dynamic){progress.append("Cache unavailable: "+Std.string(error)+"\n");}
		}
		try {
			if(isCancelled())throw "Preview build cancelled.";
            var inputs=value.args;
            if(value.family=="haxe" && value.manifest!=null && StringTools.endsWith(value.manifest,".hxml"))inputs=rayde.lang.Hxml.read(value.manifest);
            var target=RunPlan.selected(value.cwd,inputs,value.family,true);
            var configuration=RunConfigurations.load(value.cwd,target,true,value.family);
            if(configuration.mode!="browser")throw "Choose a browser-compatible Run Configuration for this target in Build Settings.";
            var marker="{preview}",model=RunPlan.make(value.compiler,inputs,value.cwd,marker,configuration,true,"{support}",true);
            var primary=model.program.indexOf(marker+"/")==0 ? model.program.substr(marker.length+1) : "app.js";
            var output=model.output.indexOf(marker+"/")==0 ? model.output.substr(marker.length+1) : primary;
            var root=haxe.io.Path.normalize(value.client.root),cwd=haxe.io.Path.normalize(value.cwd);
            var assets=configuration.previewDirectory=="" ? "" : rayde.files.FileOps.relative(root,haxe.io.Path.normalize(haxe.io.Path.isAbsolute(configuration.previewDirectory) ? configuration.previewDirectory : haxe.io.Path.join([cwd,configuration.previewDirectory])));
            var runner=model.postBuild==null ? {command:"",args:[]} : {command:model.postBuild.command,args:model.postBuild.args};
            progress.stage("Checking build inputs");
            prepared=value.client.request("preview.prepare",{recipe:{compiler:value.compiler,args:inputs.concat(configuration.compilerFlags),cwd:cwd==root ? "" : rayde.files.FileOps.relative(root,cwd),family:configuration.compiler,primary:primary,output:output,runner:runner,assets:assets,entry:configuration.previewEntry},force:value.force});
            if(prepared.cacheNote!=null && prepared.cacheNote!="")progress.append("Cache: "+prepared.cacheNote+"\n");
            var plan=RunPlan.make(value.compiler,inputs,value.cwd,prepared.directory,configuration,true,prepared.support,true);
            function execute(step:RunPlan.RunCommand,?environment:Dynamic):Void {
                if(step==null)return;
                progress.stage(step.phase);var before=haxe.Timer.stamp();
                run(step.command,step.args,environment);
                progress.append(step.phase+": "+Math.round((haxe.Timer.stamp()-before)*100)/100+"s\n");
            }
            function collect():Void {
                value.client.request("preview.collect",{path:prepared.path,source:assets,entry:configuration.previewEntry,script:primary});
            }
            if(prepared.cached=="wasm")progress.append("Reusing unchanged preview bundle.\n");
            else {
                if(prepared.cached=="bytecode")progress.append("Reusing unchanged compiler output.\n");
                else {execute(plan.compile);if(plan.postBuild==null)collect();cache("bytecode");}
                if(plan.postBuild!=null){
                    var environment:Dynamic={ASH_WASM_FIBERS:"1"};
                    if(prepared.runtime!=null)Reflect.setField(environment,"ASH_RUNTIME",prepared.runtime);
                    execute(plan.postBuild,environment);collect();
                }
                cache("wasm");
            }
			if(isCancelled())throw "Preview build cancelled.";
			progress.stage("Opening preview");
			opened=value.client.request("preview.open",{path:prepared.path});
			if(isCancelled())throw "Preview build cancelled.";
			progress.stage("Preview ready");
			return {artifact:{preview:opened.preview,url:opened.url,path:prepared.path,arguments:configuration.arguments.copy()},output:progress.snapshot().output};
		}catch(error:Dynamic){
			progress.append(Std.string(error)+"\n");
			if(value.client.isOnline() && value.client.connectionEpoch()==epoch) {
				if(opened!=null)try value.client.request("preview.close",{preview:opened.preview})catch(_:Dynamic){};
				if(prepared!=null)try value.client.request("preview.discard",{path:prepared.path})catch(_:Dynamic){};
			}
			throw error;
		}
	}
}
