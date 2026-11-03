import rayde.workspace.Fs;
import rayde.workspace.MemoryWorkspace;
import rayde.workspace.RoutedWorkspace;
import rayde.workspace.session.Channel;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.SessionWorkspace;

class SessionTreeChecks {
	static function check(ok:Bool,message:String):Void if(!ok)throw message;
	static function main():Void {
		for(cached in [false,true]) {
			var wire=new TreeChannel(cached),client=SessionClient.over(wire),workspace=new SessionWorkspace(client);
			var rows=workspace.treeEntries("/work/src");
			check(rows.length==2&&rows[0].name=="Main.hx"&&!rows[0].directory&&rows[1].directory,"Directory metadata lost names or file kinds");
			check(wire.sent.length==1&&wire.sent[0].op==(cached?"page.tree.list":"fs.list"),"Tree navigation issued per-child metadata calls");
			workspace.refreshTree("/work/src");
			check(wire.sent.length==(cached?2:1),"Refresh did not honor cache capability");
			var sources=new SessionWorkspace(client,{id:"library",path:"/installed/library"});sources.treeEntries("/installed/library");
			check(wire.sent[wire.sent.length-1].mount=="library","Dependency listings escaped their read-only mount");
			workspace.stat("/work/src/Main.hx");check(wire.sent[wire.sent.length-1].op=="fs.stat","Build/file metadata checks were redirected to the navigation cache");
			var memory=new MemoryWorkspace();memory.createDirectory("/home");memory.saveContent("/home/local.txt","local");memory.saveContent("/home/session","hidden by mount");
			var routed=new RoutedWorkspace(memory);routed.mount("/home/session",workspace);
			rows=Fs.treeEntries("/home",routed);
			check(rows.length==2&&Lambda.exists(rows,r->r.name=="session"&&r.directory)&&Lambda.exists(rows,r->r.name=="local.txt"&&!r.directory),"Routed listings omitted local files or mounted folders");
			client.close();
		}
		Sys.println("Explorer metadata: one listing, no child stat calls, cache capability, refresh, read-root isolation and authoritative stat passed");
	}
}
private class TreeChannel implements Channel {
	final incoming=new sys.thread.Deque<String>();
	final cached:Bool;
	public final sent:Array<Dynamic>=[];
	public function new(cached:Bool)this.cached=cached;
	public function sendText(text:String):Void {
		var request:Dynamic=haxe.Json.parse(text),reply:Dynamic={id:request.id,ok:true};
		if(request.op=="hello"){reply.root="/work";reply.treeCache=cached;}
		else {
			sent.push(request);
			if(request.op=="fs.list"||request.op=="page.tree.list")reply.entries=[{name:"Main.hx",kind:"file",size:1,mtime:1},{name:"nested",kind:"dir",size:0,mtime:1}];
			if(request.op=="fs.stat")reply.entry={name:"Main.hx",kind:"file",size:1,mtime:1};
		}
		incoming.add(haxe.Json.stringify(reply));
	}
	public function receive(seconds:Float):Null<String>{var text=incoming.pop(true);if(text=="closed")throw "closed";return text;}
	public function close():Void incoming.add("closed");
}
