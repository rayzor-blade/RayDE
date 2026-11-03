import ashui.components.code.CodeEditorState;
import ashui.components.code.CodeHistory.CodeSelection;
import rayde.workspace.session.Channel;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.EditorDocuments;

@:access(rayde.workspace.PageHost)
class SessionEditorChecks {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;
	static function main():Void {
		var wire = new EditorChannel(), client = SessionClient.over(wire), changes:Array<Bool> = [], failures:Array<String> = [], warnings:Array<String> = [];
		check(client.documentMoves,"the page advertises coordinated document moves");
		rayde.workspace.PageHost.session = client;
		var storage = rayde.workspace.PageHost.personalRoot("/work");
		check(storage != rayde.workspace.PageHost.personalRoot("/work/other"),"projects within one session keep separate personal metadata");
		check(StringTools.startsWith(storage,"/home/web/"),"personal history is browser-local");
		rayde.workspace.PageHost.session = null;
		var state = new CodeEditorState(), cursor:CodeSelection = {caret:3,anchor:3}, selectedFile = "", composingFile = "", changedFile = "";
		state.value.set("abc");
		var docs = new EditorDocuments(client, (file, local) -> { changedFile = file; changes.push(local); }, failures.push,
			file -> { selectedFile = file; return cursor; }, file -> { composingFile = file; return false; }, warnings.push);
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
		check(docs.save("/work/a.txt", (error, text, savedFile) -> { saved = true; refused = error != null; check(text == "remote abc","save captures its own buffer version"); }),"shared saves use the document binding");
		var save = wire.sent.pop(true);
		check(save.op == "view.save" && !saved && !docs.readOnly("/work/a.txt"),"save waits without blocking typing or completing early");
		state.value.set("remote abc!"); docs.acceptBuffer("/work/a.txt"); wire.sent.pop(true);
		wire.reply({id:save.id,ok:false,code:"offline",message:"Offline"});
		settle(client,docs,() -> saved);
		check(refused && state.value.get() == "remote abc!","failed saves preserve edits made while saving");
		var completedPath:Null<String> = null;
		docs.save("/work/a.txt",(error,text,file) -> { check(error == null && text == "remote abc!","pending Save keeps its captured text"); completedPath = file; });
		var pendingMoveSave = wire.sent.pop(true);
		var keptCaret = state.caret, keptAnchor = state.anchor, releaseMove = docs.hold("/work/a.txt");
		docs.remap("/work/a.txt","/work/src/renamed.txt");
		check(!docs.owns("/work/a.txt") && docs.owns("/work/src/renamed.txt"),"confirmed moves retain the binding under its new path");
		check(state.caret == keptCaret && state.anchor == keptAnchor,"moving a binding preserves its editor selection");
		check(docs.readOnly("/work/src/renamed.txt") && docs.message("/work/src/renamed.txt") == "Moving document…","path-based workbench owners remap while the projection is held");
		wire.reply({id:pendingMoveSave.id,ok:true,result:{}});
		releaseMove();
		settle(client,docs,() -> completedPath != null);
		check(completedPath == "/work/src/renamed.txt","Save completions use the binding path after a move");
		state.value.set("remote abc!!"); docs.acceptBuffer("/work/src/renamed.txt");
		var movedEdit = wire.sent.pop(true);
		check(movedEdit.op == "view.edit" && movedEdit.handle == open.handle && movedEdit.serial == 4,"moving keeps the same transaction handle and sequence");
		check(selectedFile == "/work/src/renamed.txt","selection callbacks follow the moved binding");
		var releaseProjection = docs.hold("/work/src");
		wire.reply({ev:"view.remote",handle:open.handle,serial:4,epoch:2,text:"prefix remote abc!!",parts:[{from:0,removed:"",inserted:"prefix "}]});
		var pumped = false, unsubscribeMove = client.subscribe(event -> { if (event.ev == "view.remote") pumped = true; });
		settle(client,docs,() -> pumped);
		check(state.value.get() == "remote abc!!","held projections wait for all path owners before applying");
		releaseProjection(); unsubscribeMove();
		settle(client,docs,() -> state.value.get() == "prefix remote abc!!");
		check(wire.sent.pop(true).accept == true && changedFile == "/work/src/renamed.txt" && composingFile == changedFile,"remote projection callbacks use the new path");
		var reason = "The workspace changed. Reopen it to continue.";
		wire.reply({ev:"view.error",handle:open.handle,code:"workspace-changed",message:reason});
		settle(client,docs,() -> docs.readOnly("/work/src/renamed.txt"));
		check(failures.length == 0,"context changes do not repeat warnings as per-file status messages");
		var notices = 0, unsubscribe = client.subscribe(event -> { if (event.ev == "session.disconnected" && event.code == "workspace-changed") notices++; });
		for (_ in 0...2) wire.reply({ev:"session.disconnected",generation:1,code:"workspace-changed",message:reason});
		settle(client,docs,() -> notices == 2);
		check(warnings.length == 1 && warnings[0] == reason,"one session-level warning reaches the toast callback");
		check(state.value.get() == "prefix remote abc!!" && docs.message("/work/src/renamed.txt") == "Document sync paused","the warning preserves the read-only recovery fence and text");
		unsubscribe();
		rayde.workspace.PageHost.bridge = client;
		var reopening = rayde.workspace.PageHost.reopen(), reopen = wire.sent.pop(true);
		check(reopen.op == "page.reopen" && !reopening.isReady(),"reopen travels asynchronously through the page bridge while the remote session is disconnected");
		wire.reply({id:reopen.id,ok:true});
		settle(client,docs,() -> reopening.isReady()); reopening.await();
		rayde.workspace.PageHost.bridge = null;
		docs.release("/work/src/renamed.txt");
		check(wire.sent.pop(true).op == "view.close" && state.onUndo == null && state.onTransaction == null,"closing releases protocol and editor hooks");
		check(!docs.owns("/work/src/renamed.txt") && failures.length == 0,"no document binding remains after release");
		wire.reply({ev:"session.connected",generation:2,documentMoves:false});
		settle(client,docs,() -> !client.documentMoves);
		check(!client.documentMoves,"reconnect updates move support before allowing new mutations");
		docs.close(); client.close();
		for (initial in ["saved", "buffer"]) {
			var restoredWire = new EditorChannel(), restoredClient = SessionClient.over(restoredWire), restoredState = new CodeEditorState();
			var restoredChanges:Array<Bool> = [];
			restoredState.value.set(initial);
			var restoredDocs = new EditorDocuments(restoredClient, (_, local) -> restoredChanges.push(local), message -> { throw message; }, _ -> {caret:0,anchor:0}, _ -> false);
			restoredDocs.attach("/work/recovered.txt", restoredState, "saved");
			var request = restoredWire.sent.pop(true);
			restoredWire.reply({id:request.id,ok:true,result:{text:"buffer",epoch:0,serial:0,dirty:true}});
			settle(restoredClient,restoredDocs,() -> !restoredDocs.readOnly("/work/recovered.txt"));
			check(restoredState.value.get() == "buffer" && restoredChanges.length == 1 && restoredChanges[0],"restored unsaved buffers become dirty even when their text already matches browser recovery");
			restoredWire.sent.pop(true);
			restoredDocs.close(); restoredClient.close();
		}
		var localWire=new EditorChannel(),localClient=SessionClient.over(localWire),localState=new CodeEditorState();localState.value.set("saved");
		rayde.ui.DocumentHistory.edit(localState,"saved draft",[{from:5,removed:"",inserted:" draft"}]);
		var history=haxe.Json.stringify(rayde.ui.DocumentHistory.snapshot(localState));
		var localDocs=new EditorDocuments(localClient,(_,_) -> {},message -> {throw message;},_ -> {caret:0,anchor:0},_ -> false);
		localDocs.attach("/work/legacy.txt",localState,"saved");var legacy=localWire.sent.pop(true);
		localWire.reply({id:legacy.id,ok:true,result:{passthrough:true,syncMessage:"Live sync needs recovery reconciliation"}});
		settle(localClient,localDocs,() -> !localDocs.readOnly("/work/legacy.txt"));
		check(!localDocs.owns("/work/legacy.txt")&&localState.onTransaction==null&&localState.onUndo==null,"legacy documents retain their original transaction owner");
		check(haxe.Json.stringify(rayde.ui.DocumentHistory.snapshot(localState))==history,"passthrough preserves legacy undo and unsaved text");
		check(!localDocs.save("/work/legacy.txt",(_,_,_) -> {throw "unexpected shared Save";}),"unbound documents use their ordinary save path");
		var jamUndo:Bool->Void=_ -> {};localState.onUndo=jamUndo;localDocs.release("/work/legacy.txt");check(localState.onUndo==jamUndo,"closing a passive cloud binding cannot erase a later Jam owner");
		localDocs.close();localClient.close();
		Sys.println("session editor: readiness, projections, edits, undo, save failure, legacy passthrough and release passed");
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
		if (message.op == "hello") reply({id:message.id,ok:true,root:"/work",name:"work",exec:false,documentBridge:true,documentMoves:true,storageKey:"workspace"});
		else { sent.add(message); sentCount++; }
	}
	public function receive(seconds:Float):Null<String> { var value = incoming.pop(true); if (value == "closed") throw "closed"; return value; }
	public function close():Void incoming.add("closed");
}
