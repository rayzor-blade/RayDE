package rayde.run;

import rayde.workspace.Program;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.SessionLauncher;
import ashui.reactive.Signal;

private typedef Build = {client:SessionClient, compiler:String, args:Array<String>, cwd:String, progress:BuildProgress, force:Bool};
typedef AppArtifact = {preview:String, url:String, path:String};

/** One supervised browser build per window. Compiler work and output readers stay off the UI thread. */
class AppPreviewBuild {
	public final artifact = Signal.make((null:Null<AppArtifact>));
	public final state = Signal.make("idle");
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
			if(event.ev!="session.disconnected" || gone)return;
			worker.cancel("app");artifact.set(null);state.set("failed");error.set("The session disconnected. Rebuild the preview after reconnecting.");
			if(progress!=null)progress.append(error.get()+"\n");
		});
	}
	public function start(compiler:String,args:Array<String>,cwd:String,force=false):Void {
		if (state.get() == "building") return;
		if(timer!=null)timer.cancel();
		state.set("building");error.set("");output.set("");phase.set("Preparing preview");elapsed.set(0);
		started=haxe.Timer.stamp();seen=-1;progress=new BuildProgress();
		worker.submit("app",{client:client,compiler:compiler,args:args.copy(),cwd:cwd,progress:progress,force:force});poll();
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
	public static function compilerArgs(args:Array<String>,support:String,output:String):Array<String> {
		var result:Array<String>=[],at=0;
		while(at<args.length){
			var flag=args[at++];
			if (["--next","--each","--interp","--run","-x","-js","--js","-cpp","--cpp","-neko","-python","-java","-cs","-php","-lua","--no-output","--cmd","-cmd"].indexOf(flag)>=0)
				throw "App Preview needs a single HashLink build with browser-compatible libraries.";
			if(flag=="-hl"||flag=="--hl"){at++;continue;}
			result.push(flag);
		}
		return result.concat(["-cp",support,"-D","wasm","-hl",output]);
	}
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
			var root=haxe.io.Path.normalize(value.client.root),cwd=haxe.io.Path.normalize(value.cwd);
			progress.stage("Checking build inputs");
			prepared=value.client.request("preview.prepare",{recipe:{compiler:value.compiler,args:value.args,cwd:cwd==root ? "" : rayde.files.FileOps.relative(root,cwd)},force:value.force});
			if(prepared.cacheNote!=null && prepared.cacheNote!="")progress.append("Cache: "+prepared.cacheNote+"\n");
			var program:String=prepared.directory+"/app.hl",wasm:String=prepared.directory+"/app.wasm";
			if(prepared.cached=="wasm")progress.append("Reusing unchanged WASM preview.\n");
			else {
				if(prepared.cached=="bytecode")progress.append("Reusing unchanged HashLink bytecode.\n");
				else {
					progress.stage("Compiling Haxe");var before=haxe.Timer.stamp();
					run(value.compiler,compilerArgs(value.args,prepared.support,program));
					progress.append("Haxe compile: "+Math.round((haxe.Timer.stamp()-before)*100)/100+"s\n");
					cache("bytecode");
				}
				var environment:Dynamic={ASH_WASM_FIBERS:"1"};
				if(prepared.runtime!=null)Reflect.setField(environment,"ASH_RUNTIME",prepared.runtime);
				progress.stage("Compiling WASM");var before=haxe.Timer.stamp();
				run("ash",["--build",wasm,"--target","wasm32-wasip1-threads",program],environment);
				progress.append("WASM compile: "+Math.round((haxe.Timer.stamp()-before)*100)/100+"s\n");
				cache("wasm");
			}
			if(isCancelled())throw "Preview build cancelled.";
			progress.stage("Opening preview");
			opened=value.client.request("preview.open",{path:prepared.path});
			if(isCancelled())throw "Preview build cancelled.";
			progress.stage("Preview ready");
			return {artifact:{preview:opened.preview,url:opened.url,path:prepared.path},output:progress.snapshot().output};
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
