import ashui.components.CodeEditor;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.ui.Ref;
import rayde.ui.SessionSyntax;
import rayde.workspace.session.Channel;
import rayde.workspace.session.SessionClient;

class SessionSyntaxChecks {
	static function check(ok:Bool,message:String):Void if (!ok) throw message;
	static function main():Void {
		for (entry in [{file:"module.MJS",language:"javascript"},{file:"App.tsx",language:"typescript"},{file:"main.rs",language:"rust"},{file:"theme.css",language:"css"},{file:"script.py",language:"python"},{file:"main.lua",language:"lua"},{file:"project.toml",language:"plain"}])
			check(rayde.ui.EditorSyntax.languageOf(entry.file)==entry.language,"Wrong immediate grammar for "+entry.file);
		var wire=new SyntaxChannel(),client=SessionClient.over(wire);
		check(client.syntax,"Session syntax capability was not accepted");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),Dark);
		var tree=new LayoutTree(),ref=new Ref<CodeEditor>(),source=Signal.make("first = 1"),dispose:Void->Void=null,syntax:SessionSyntax=null;
		var hooks=0;
		var root=Owner.root(tree,cleanup->{dispose=cleanup;syntax=new SessionSyntax(client,"/work/config.toml",source);return <div width={800} height={500} class="flex flex-col"><code-editor ref={ref} value={source} highlighterSource={syntax.highlighter} class="flex-1 min-h-0"/></div>;});
		function settle():Void {client.drain();ashui.core.render.Offscreen.advance(.04);Css.setViewport(800,500);Css.update();tree.flush();tree.computeLayout(root.node,800,500);}
		function until(done:Void->Bool):Void {var end=haxe.Timer.stamp()+5;while(!done()&&haxe.Timer.stamp()<end){settle();Sys.sleep(.005);}check(done(),"Syntax worker did not settle");}
		function request():Dynamic {var value:Dynamic=null;until(()->{if(value==null)value=wire.sent.pop(false);return value!=null;});return value;}
		try {
			var first=request();hooks=LayoutTree.flushHooks.length-1;source.set("second = 2");for(_ in 0...5)settle();
			wire.reply({id:first.id,ok:true,tokens:[[{from:0,to:9,kind:"keyword"}]]});
			var second=request();check(second.source=="second = 2"&&syntax.highlighter.get()==null,"A stale snapshot was applied or the latest source was lost");
			wire.reply({id:second.id,ok:false,code:"busy",message:"Busy"});
			var retry=request();check(retry.source=="second = 2","Busy retry used an older snapshot");
			wire.reply({id:retry.id,ok:true,tokens:[[{from:0,to:10,kind:"string"}]]});
			until(()->ref.get().document.lines[0].tokenCount>0&&ref.get().document.lines[0].tokenKind(0)=="string");
			var tables:Array<Dynamic>=Reflect.field(syntax.highlighter.get(),"lines");check(tables.length==0,"Consumed token tables were retained beside the packed document");
			source.set("pending = 3");var pending=request();dispose();
			wire.reply({id:pending.id,ok:true,tokens:[[{from:0,to:11,kind:"keyword"}]]});
			check(LayoutTree.flushHooks.length==hooks,"Closing the view retained a syntax frame hook");
			check(wire.cancellations>0,"Edits and closing never cancelled remote work");
			Sys.println("Session syntax: language aliases, stale snapshots, busy retry, packed-token ownership and cleanup passed");
		} catch(error:Dynamic) {dispose();tree.dispose();client.close();throw error;}
		tree.dispose();client.close();
	}
}

private class SyntaxChannel implements Channel {
	final incoming=new sys.thread.Deque<String>();
	public final sent=new sys.thread.Deque<Dynamic>();
	public var cancellations=0;
	public function new() {}
	public function reply(value:Dynamic):Void incoming.add(haxe.Json.stringify(value));
	public function sendText(text:String):Void {
		var request:Dynamic=haxe.Json.parse(text);
		if(request.op=="hello")reply({id:request.id,ok:true,root:"/work",name:"work",exec:false,syntax:true});
		else if(request.op=="syntax.cancel")cancellations++;
		else if(request.op=="syntax.highlight")sent.add(request);
	}
	public function receive(seconds:Float):Null<String> {var text=incoming.pop(true);if(text=="closed")throw "closed";return text;}
	public function close():Void incoming.add("closed");
}
