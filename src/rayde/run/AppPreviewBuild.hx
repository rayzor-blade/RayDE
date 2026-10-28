package rayde.run;

import rayde.workspace.Program;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.SessionLauncher;
import ashui.reactive.Signal;

private typedef Build = {client:SessionClient, compiler:String, args:Array<String>, cwd:String};
typedef AppArtifact = {preview:String, url:String, path:String};

/** One supervised browser build per window. Compiler work and output readers stay off the UI thread. */
class AppPreviewBuild {
	public final artifact = Signal.make((null:Null<AppArtifact>));
	public final state = Signal.make("idle");
	public final error = Signal.make("");
	public final output = Signal.make("");
	final client:SessionClient;
	final unsubscribe:Void->Void;
	final worker = new Worker<Build,{artifact:AppArtifact,output:String}>(build, () -> ashui.core.Work.notify());
	var timer:Null<ashui.animation.AnimationScheduler.Timer>;
	var gone = false;
	public function new(client:SessionClient) {
		this.client=client;
		unsubscribe=client.subscribe(event -> {
			if(event.ev!="session.disconnected" || gone)return;
			worker.cancel("app");artifact.set(null);state.set("failed");error.set("The session disconnected. Rebuild the preview after reconnecting.");
		});
	}
	public function start(compiler:String,args:Array<String>,cwd:String):Void {
		if (state.get() == "building") return;
		state.set("building");error.set("");
		worker.submit("app",{client:client,compiler:compiler,args:args.copy(),cwd:cwd});poll();
	}
	function poll():Void {
		if (gone) return;
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
		var epoch=value.client.connectionEpoch(),wasCancelled=cancelled;
		cancelled=() -> wasCancelled() || !value.client.isOnline() || value.client.connectionEpoch()!=epoch;
		var prepared:Dynamic=null,opened:Dynamic=null;
		var log="",mutex=new sys.thread.Mutex();
		function append(text:String):Void {mutex.acquire();log+=text;if(log.length>512*1024)log=log.substr(log.length-512*1024);mutex.release();}
		function run(command:String,args:Array<String>,?env:Dynamic):Void {
			if(cancelled())throw "Preview build cancelled.";
			var launcher:SessionLauncher=cast rayde.workspace.Procs.current;
			var process:Program=launcher.startConfigured(command,args,value.cwd,env).await();
			var readers=new sys.thread.Lock();
			for(input in [process.stdout,process.stderr])sys.thread.Thread.create(() -> {
				try {var bytes=haxe.io.Bytes.alloc(8192);while(true){var size=input.readBytes(bytes,0,bytes.length);if(size==0)break;append(bytes.sub(0,size).toString());}}catch(_:haxe.io.Eof){}catch(e:Dynamic){append(Std.string(e));}
				readers.release();
			});
			var end=haxe.Timer.stamp()+180.,code:Null<Int>=null;
			try {
				process.stdin.close();
				while((code=process.exitCode(false))==null){
					if(cancelled()||haxe.Timer.stamp()>end)throw "Preview build cancelled or timed out.";
					Sys.sleep(.03);
				}
				readers.wait(2);readers.wait(2);
				if(code!=0)throw "Preview build failed.\n"+log;
			} catch(error:Dynamic){try process.kill() catch(_:Dynamic){};process.close();throw error;}
			process.close();
		}
		try {
			prepared=value.client.request("preview.prepare");
			var program:String=prepared.directory+"/app.hl",wasm:String=prepared.directory+"/app.wasm";
			run(value.compiler,compilerArgs(value.args,prepared.support,program));
			var environment:Dynamic={ASH_WASM_FIBERS:"1"};
			if(prepared.runtime!=null)Reflect.setField(environment,"ASH_RUNTIME",prepared.runtime);
			run("ash",["--build",wasm,"--target","wasm32-wasip1-threads",program],environment);
			if(cancelled())throw "Preview build cancelled.";
			opened=value.client.request("preview.open",{path:prepared.path});
			if(cancelled())throw "Preview build cancelled.";
			return {artifact:{preview:opened.preview,url:opened.url,path:prepared.path},output:log};
		}catch(error:Dynamic){
			if(value.client.isOnline() && value.client.connectionEpoch()==epoch) {
				if(opened!=null)try value.client.request("preview.close",{preview:opened.preview})catch(_:Dynamic){};
				if(prepared!=null)try value.client.request("preview.discard",{path:prepared.path})catch(_:Dynamic){};
			}
			throw error;
		}
	}
}
