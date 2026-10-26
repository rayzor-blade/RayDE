import ashui.components.code.CodeEditorState;
import ashui.components.code.CodeHistory.CodeSelection;
import rayde.workspace.session.Channel;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.EditorDocuments;

@:access(rayde.workspace.PageHost)
class SessionEditorChecks {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;
	static function main():Void {
		var wire = new EditorChannel(), client = SessionClient.over(wire), changes:Array<Bool> = [], failures:Array<String> = [];
		rayde.workspace.PageHost.session = client;
		var storage = rayde.workspace.PageHost.personalRoot("/work");
		check(storage != rayde.workspace.PageHost.personalRoot("/work/other"),"projects within one session keep separate personal metadata");
		check(StringTools.startsWith(storage,"/home/web/"),"personal history is browser-local");
		rayde.workspace.PageHost.session = null;
		var state = new CodeEditorState(), cursor:CodeSelection = {caret:3,anchor:3};
		state.value.set("abc");
		var docs = new EditorDocuments(client, (_, local) -> changes.push(local), failures.push,
			_ -> cursor, _ -> false);
		docs.attach("/work/a.txt",state,"abc");
		check(docs.readOnly("/work/a.txt"),"the editor must wait asynchronously for its CRDT projection");
		var open = wire.sent.pop(true);
		check(open.op == "view.open" && open.path == "a.txt","paths are relative to the session");
		wire.reply({id:open.id,ok:true,result:{text:"abc",epoch:0,serial:0}});
		settle(client,docs,() -> !docs.readOnly("/work/a.txt"));
		check(wire.sent.pop(true).op == "view.ready","initial projection must be acknowledged before typing");
		state.value.set("abc!"); docs.acceptBuffer("/work/a.txt");
		var edit = wire.sent.pop(true);
		check(edit.op == "view.edit" && edit.serial == 1 && edit.parts[0].from == 3,"external edits must use the same ordered transaction stream");
		wire.reply({ev:"view.remote",handle:open.handle,serial:0,epoch:1,text:"remote abc",parts:[{from:0,removed:"",inserted:"remote "}]});
		settle(client,docs,() -> wire.sentCount > 3);
		check(wire.sent.pop(true).accept == false && state.value.get() == "abc!","stale remote projections must preserve late typing");
		wire.reply({ev:"view.remote",handle:open.handle,serial:1,epoch:1,text:"remote abc!",parts:[{from:0,removed:"",inserted:"remote "}]});
		settle(client,docs,() -> state.value.get() == "remote abc!");
		check(wire.sent.pop(true).accept == true,"current projection must be acknowledged");
		check(state.caret == 10 && state.anchor == 10,"remote patches transform UTF-16 selection offsets");
		check(changes.length == 1 && changes[0] == false,"remote edits do not pretend to be local edits");
		state.onUndo(false);
		var undo = wire.sent.pop(true);
		check(docs.readOnly("/work/a.txt") && undo.op == "view.undo" && undo.serial == 2,"undo is local to this document and asynchronous");
		wire.reply({id:undo.id,ok:true,result:{text:"remote abc",parts:[{from:10,removed:"!",inserted:""}]}});
		settle(client,docs,() -> !docs.readOnly("/work/a.txt"));
		check(state.value.get() == "remote abc" && changes[1] == true,"undo must report a local edit after its result is applied");
		var saved = false, refused = false;
		check(docs.save("/work/a.txt", (error, text) -> { saved = true; refused = error != null; check(text == "remote abc","save captures its own buffer version"); }),"shared saves use the document binding");
		var save = wire.sent.pop(true);
		check(save.op == "view.save" && !saved && !docs.readOnly("/work/a.txt"),"save waits without blocking typing or completing early");
		state.value.set("remote abc!"); docs.acceptBuffer("/work/a.txt"); wire.sent.pop(true);
		wire.reply({id:save.id,ok:false,code:"offline",message:"Offline"});
		settle(client,docs,() -> saved);
		check(refused && state.value.get() == "remote abc!","failed saves preserve edits made while saving");
		docs.release("/work/a.txt");
		check(wire.sent.pop(true).op == "view.close" && state.onUndo == null && state.onTransaction == null,"closing releases protocol and editor hooks");
		check(!docs.owns("/work/a.txt") && failures.length == 0,"no document binding remains after release");
		docs.close(); client.close();
		Sys.println("session editor: readiness, stale projections, edits, undo, nonblocking save failure and release passed");
	}
	static function settle(client:SessionClient, docs:EditorDocuments, ready:Void->Bool):Void {
		var end = haxe.Timer.stamp() + 3;
		while (!ready()) {
			client.drain(); docs.frame();
			if (haxe.Timer.stamp() > end) throw "Session editor did not settle";
			Sys.sleep(.001);
		}
	}
}

private class EditorChannel implements Channel {
	final incoming = new sys.thread.Deque<String>();
	public final sent = new sys.thread.Deque<Dynamic>();
	public var sentCount = 0;
	public function new() {}
	public function reply(message:Dynamic):Void incoming.add(haxe.Json.stringify(message));
	public function sendText(text:String):Void {
		var message:Dynamic = haxe.Json.parse(text);
		if (message.op == "hello") reply({id:message.id,ok:true,root:"/work",name:"work",exec:false,documentBridge:true,storageKey:"workspace"});
		else { sent.add(message); sentCount++; }
	}
	public function receive(seconds:Float):Null<String> { var value = incoming.pop(true); if (value == "closed") throw "closed"; return value; }
	public function close():Void incoming.add("closed");
}
