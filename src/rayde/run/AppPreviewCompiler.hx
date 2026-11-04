package rayde.run;

import rayde.workspace.Program;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.SessionLauncher;

typedef PreviewArtifact = {preview:String, url:String, path:String, ?arguments:Array<String>, ?cached:Bool};

typedef PreviewBuild = {client:SessionClient, compiler:String, args:Array<String>, cwd:String, progress:BuildProgress, force:Bool, family:String, manifest:Null<String>};

/** Shared compiler supervision and caching, independent of editor views. */
class AppPreviewCompiler {
	public static function build(value:PreviewBuild,cancelled:Void->Bool):{artifact:PreviewArtifact,output:String} {
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
            if (value.client.demoPreview) {
                progress.stage("Checking demo inputs");
                var cached=value.client.request("page.demo-preview",{root:value.cwd,configuration:configuration,force:value.force});
                if(cached.available==true) {
                    progress.append("Opening the prebuilt Pocket Studio app.\n");progress.stage("Preview ready");
                    return {artifact:{preview:cached.preview,url:cached.url,path:"",cached:true,arguments:configuration.arguments.copy()},output:progress.snapshot().output};
                }
                if(!value.client.exec)throw "These sources need a new build. Connect a workspace session to rebuild the app.";
            }
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
