import ashui.core.render.Offscreen;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.workspace.Fs;
import rayde.workspace.PageHost;
import rayde.workspace.session.Channel;
import rayde.workspace.session.SessionClient;

@:access(rayde.workspace.PageHost)
class DeferredWorkbenchChecks {
	static function check(ok:Bool,message:String):Void if (!ok) throw message;
	static function main():Void {
		var previous = Fs.current, previousSession = PageHost.session, home = Sys.getEnv("HOME"), extensions = Sys.getEnv("RAYDE_EXTENSIONS");
		var memory = new rayde.workspace.MemoryWorkspace(); Fs.current = memory;
		for (path in ["/work/src","/work/extensions","/home/check"]) memory.createDirectory(path);
		Sys.putEnv("HOME","/home/check"); Sys.putEnv("RAYDE_EXTENSIONS","/work/extensions");
		memory.saveContent("/work/build.hxml","-cp src\n-main Main\n-hl bin/main.hl\n");
		memory.saveContent("/work/src/Main.hx","class Main {static function main(){}}");
		var wire = new DeferredChannel(), client = SessionClient.over(wire); PageHost.session = client;
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),Dark); rayde.ui.Style.use();
		var tree = new LayoutTree(), compiler = new rayde.lang.CompilerServer(), stop:Void->Void = null;
		var bench = Owner.root(tree,cleanup -> {stop=cleanup;return new rayde.ui.Workbench({display:rayde.lang.Display.ofHxml(compiler,"/work/build.hxml"),name:"Pocket Studio"});});
		function frame():Void {client.drain();Offscreen.advance(.03);Css.update();tree.flush();tree.computeLayout(bench.node,1100,760);}
		function nodes(selector:String) return Css.query(tree,bench.node.id,selector);
		function until(done:Void->Bool):Void {
			var end=haxe.Timer.stamp()+5;
			while (!done() && haxe.Timer.stamp()<end) {frame();Sys.sleep(.002);}
			check(done(),"Deferred workbench did not settle");
		}
		try {
			for (_ in 0...5) frame();
			check(nodes("#rayde-build-action:disabled").length==1 && nodes("#rayde-run:disabled").length==1,"Compute controls were enabled before admission");
			wire.reply({ev:"demo.status",status:"failed",message:"All demo sessions are busy. Edits are kept locally."});
			until(() -> nodes("#rayde-demo-reconnect").length==1);
			check(nodes(".ui-toast").length==0,"Admission replaced local editing with a notification overlay");
			var button=tree.getScrolledBounds(new ashui.layout.Node(nodes("#rayde-demo-reconnect")[0]));
			check(button.width>0 && button.y>700 && button.x+button.width<=1100,"Reconnect escaped the status bar");
			ashui.input.Pointer.move(tree,button.x+button.width/2,button.y+button.height/2);
			ashui.input.Pointer.press(tree);ashui.input.Pointer.release(tree);
			until(() -> wire.retries==1);
			ashui.core.render.Snapshot.capture("deferred-workspace-offline",tree,bench.node,1100,760);
		} catch (error:Dynamic) {
			stop();tree.dispose();compiler.stop();client.close();Fs.current=previous;PageHost.session=previousSession;Sys.putEnv("HOME",home);Sys.putEnv("RAYDE_EXTENSIONS",extensions);throw error;
		}
		stop();tree.dispose();compiler.stop();client.close();Fs.current=previous;PageHost.session=previousSession;Sys.putEnv("HOME",home);Sys.putEnv("RAYDE_EXTENSIONS",extensions);
		Sys.println("Deferred workbench: disabled compute, offline feedback and asynchronous reconnect in the status bar passed");
	}
}

private class DeferredChannel implements Channel {
	final incoming = new sys.thread.Deque<String>();
	public var retries = 0;
	public function new() {}
	public function reply(value:Dynamic):Void incoming.add(haxe.Json.stringify(value));
	public function sendText(text:String):Void {
		var request:Dynamic=haxe.Json.parse(text),response:Dynamic={id:request.id,ok:true};
		if (request.op=="hello") {response.root="/work";response.name="Pocket Studio";response.deferred=true;response.online=false;response.demoState="waiting";response.demoMessage="Workspace connecting…";}
		if (request.op=="page.demo-retry") retries++;
		reply(response);
	}
	public function receive(seconds:Float):Null<String> {var text=incoming.pop(true);if(text=="closed")throw "closed";return text;}
	public function close():Void incoming.add("closed");
}
