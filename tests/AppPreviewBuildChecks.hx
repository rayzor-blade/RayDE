import haxe.crypto.Base64;
import haxe.io.Bytes;
import rayde.run.AppPreviewBuild;
import rayde.run.BuildProgress;
import rayde.workspace.session.Channel;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.SessionLauncher;

@:access(rayde.run.AppPreviewBuild)
class AppPreviewBuildChecks {
	static function check(ok:Bool, message:String):Void if(!ok)throw message;
	static function main():Void {
		var mailbox=new BuildProgress();
		mailbox.append(StringTools.lpad("end", "x", 600000));
		mailbox.stage("Compiling WASM");
		var snapshot=mailbox.snapshot();
		check(snapshot.output.length==512*1024 && StringTools.endsWith(snapshot.output,"Compiling WASM…\n"),"Compiler output is not bounded");
		check(snapshot.phase=="Compiling WASM" && snapshot.revision==2,"Phase did not publish with output");
		var wire=new PreviewChannel(),client=SessionClient.over(wire);
		var previous=rayde.workspace.Procs.current;
		rayde.workspace.Procs.current=new SessionLauncher(client);
		var published="",build=new AppPreviewBuild(client,text -> published=text);
		function until(done:Void->Bool):Void {
			var end=haxe.Timer.stamp()+5;
			while(!done() && haxe.Timer.stamp()<end){
				if(build.timer!=null)build.timer.cancel();
				client.pump(0);build.poll();Sys.sleep(.005);
			}
			check(done(),"Build did not settle: "+build.state.get()+" "+build.error.get()+"\n"+published);
		}
		try {
			build.start("haxe",["-main","Main","-hl","old.hl"],"/work");
			until(() -> published.indexOf("compiler output")>=0);
			check(build.state.get()=="building" && build.phase.get()=="Compiling Haxe","Running compiler has no live phase");
			wire.exit(0);
			until(() -> build.state.get()=="ready");
			check(published.indexOf("Compiling WASM")>=0 && build.artifact.get()!=null,"Successful preview lost compiler progress");
			wire.title("capability","Pocket Studio");until(() -> build.title.get()=="Pocket Studio");
            wire.title("another-preview","Wrong title");client.pump(.1);
            check(build.title.get()=="Pocket Studio","An old preview renamed the current tab");
            var spawns=wire.spawns;wire.cached="wasm";
			build.start("haxe",[],"/work");until(() -> build.state.get()=="ready");
			check(wire.spawns==spawns && published.indexOf("Reusing unchanged preview bundle")>=0,"Cached preview spawned a compiler");
			wire.cached="bytecode";
			build.start("haxe",[],"/work");until(() -> build.state.get()=="ready");
			check(wire.spawns==spawns+1 && wire.command!="haxe","Cached bytecode did not skip Haxe");
			wire.cached="wasm";
			build.start("haxe",[],"/work",true);until(() -> build.state.get()=="ready");
			check(wire.spawns==spawns+3,"Forced rebuild reused cached compiler output");wire.cached="miss";
			wire.fail=true;
			build.start("haxe",[],"/work");
			until(() -> build.state.get()=="failed");
			check(published.indexOf("compiler error")>=0 && build.error.get()!="","Failed build lost output");
			wire.fail=false;wire.hold=true;
			build.start("haxe",[],"/work");
			until(() -> published.indexOf("compiler output")>=0);
			build.stop();
			until(() -> !build.worker.busy());
			check(build.state.get()=="cancelled" && wire.killed,"Stop did not cancel the compiler");
		} catch(error:Dynamic){build.dispose();client.close();rayde.workspace.Procs.current=previous;throw error;}
		build.dispose();client.close();rayde.workspace.Procs.current=previous;
		Sys.println("App preview builds: live output, phases, bytecode/WASM reuse, forced build, failure and Stop passed");
	}
}

private class PreviewChannel implements Channel {
	final incoming=new sys.thread.Deque<String>();
	var pid=0;
	public var spawns=0;
	public var command="";
	public var cached="miss";
	public var hold=true;
	public var fail=false;
	public var killed=false;
	public function new() {}
	function reply(value:Dynamic):Void incoming.add(haxe.Json.stringify(value));
	public function title(preview:String,title:String):Void reply({ev:"preview.title",preview:preview,title:title});
	public function exit(code:Int):Void {hold=false;reply({ev:"proc.exit",pid:pid,code:code});}
	public function sendText(text:String):Void {
		var request:Dynamic=haxe.Json.parse(text),answer:Dynamic={id:request.id,ok:true};
		switch(request.op:String){
			case "hello":answer.root="/work";answer.exec=true;
			case "preview.prepare":answer.directory="/work/.rayde/previews/test";answer.support="/support";answer.path=".rayde/previews/test";answer.cached=request.force==true ? "miss" : cached;
			case "preview.open":answer.preview="capability";answer.url="http://localhost:1/preview";
			case "proc.spawn":
				spawns++;command=request.command;
				answer.pid=++pid;
				reply({ev:"proc.out",pid:pid,stream:"stdout",data:Base64.encode(Bytes.ofString(fail ? "compiler error\n" : "compiler output\n"))});
				if(!hold || fail)reply({ev:"proc.exit",pid:pid,code:fail ? 1 : 0});
			case "proc.kill":killed=true;exit(137);
			default:
		}
		reply(answer);
	}
	public function receive(seconds:Float):Null<String> {var text=incoming.pop(true);if(text=="closed")throw "closed";return text;}
	public function close():Void incoming.add("closed");
}
