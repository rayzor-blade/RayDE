import ashui.core.render.Offscreen;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;
import rayde.workspace.Fs;
import rayde.workspace.PageHost;
import rayde.workspace.session.Channel;
import rayde.workspace.session.SessionClient;

@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.RunPart)
@:access(rayde.workspace.PageHost)
@:access(rayde.workspace.session.SessionClient)
class LandingPreviewChecks {
	static function check(ok:Bool,message:String):Void if(!ok)throw message;
	static function main():Void {
		var previous=Fs.current,session=PageHost.session,home=Sys.getEnv("HOME"),extensions=Sys.getEnv("RAYDE_EXTENSIONS");
		var memory=new rayde.workspace.MemoryWorkspace();Fs.current=memory;
		for(path in ["/work/src","/work/extensions","/home/check"])memory.createDirectory(path);
		Sys.putEnv("HOME","/home/check");Sys.putEnv("RAYDE_EXTENSIONS","/work/extensions");
		memory.saveContent("/work/build.hxml","-cp src\n-L ashui\n-main Main\n-hl bin/main.hl\n");
		memory.saveContent("/work/src/Main.hx","class Main {static function main() {}}");
		rayde.settings.Store.saveChecked("/work","run",{framework:"haxe",targets:{hl:{mode:"process",runner:"auto"}}});
		var wire=new LandingChannel(),client=SessionClient.over(wire);PageHost.session=client;
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),Dark);rayde.ui.Style.use();
		var tree=new LayoutTree(),compiler=new CompilerServer(),stop:Void->Void=null;
		var bench=Owner.root(tree,cleanup->{stop=cleanup;return new Workbench({display:Display.ofHxml(compiler,"/work/build.hxml"),name:"Pocket Studio"});});
		function settle():Void {client.drain();Offscreen.advance(.025);Css.update();tree.flush();tree.computeLayout(bench.node,1100,760);}
		function ready(count:Int):Void {
			var end=haxe.Timer.stamp()+5;
			while(haxe.Timer.stamp()<end){settle();if(wire.cached>=count&&bench.runPart.appPreview!=null&&bench.runPart.appPreview.state.get()=="ready")return;Sys.sleep(.005);}
			throw "Cached landing preview did not become ready";
		}
		try {
			check(bench.runPart.browserPreviewSelected("hl")&&bench.runPart.canPreviewApp(),"A landing session with an older manifest selected a streamed preview");
			client.root="/other";check(!bench.runPart.browserPreviewSelected("hl"),"Landing defaults escaped their workspace");client.root="/work";
			memory.saveContent("/work/haxelib.json",sys.io.File.getContent("site/demo/haxelib.json"));
			bench.runPart.previewApp();ready(1);
			check(bench.active.get()==Workbench.APP_PREVIEW&&bench.runPart.surfacePreview==null,"Preview opened the streamed UI tab");
			check(bench.runPart.appPreview.artifact.get().cached==true&&wire.configuration.framework=="ashui"&&wire.configuration.compilerFlags.join(" ")=="-dce full","Old desktop preferences changed the published WASM recipe");
			check(bench.runPart.runner.configuration.mode=="process","The desktop Run Configuration was overwritten");
			bench.runPart.runSaved();ready(2);
			check(wire.spawns==0&&bench.active.get()==Workbench.APP_PREVIEW,"Landing Run launched a native program or compiler");
		} catch(error:Dynamic){stop();tree.dispose();compiler.stop();client.close();Fs.current=previous;PageHost.session=session;Sys.putEnv("HOME",home);Sys.putEnv("RAYDE_EXTENSIONS",extensions);throw error;}
		stop();tree.dispose();compiler.stop();client.close();Fs.current=previous;PageHost.session=session;Sys.putEnv("HOME",home);Sys.putEnv("RAYDE_EXTENSIONS",extensions);
		Sys.println("Landing preview: legacy preferences, scoped WASM selection, cached Preview/Run and zero process/compiler launches passed");
	}
}
private class LandingChannel implements Channel {
	final incoming=new sys.thread.Deque<String>();
	public var cached=0;
	public var spawns=0;
	public var configuration:Dynamic;
	public function new(){}
	public function sendText(text:String):Void {
		var request:Dynamic=haxe.Json.parse(text),reply:Dynamic={id:request.id,ok:true};
		switch(request.op:String){
			case "hello":reply.root="/work";reply.exec=true;reply.appPreviews=true;reply.demoPreview=true;
			case "page.demo-preview":cached++;configuration=request.configuration;reply.available=true;reply.preview="published";reply.url="http://localhost:1/index.html";
			case "proc.spawn":spawns++;reply.ok=false;reply.code="unexpected-process";reply.message="The landing preview must use its WASM artifact.";
			default:
		}
		incoming.add(haxe.Json.stringify(reply));
	}
	public function receive(seconds:Float):Null<String>{var text=incoming.pop(true);if(text=="closed")throw "closed";return text;}
	public function close():Void incoming.add("closed");
}
