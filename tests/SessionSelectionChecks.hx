import ashui.components.CodeEditor;
import ashui.components.code.CodeEditorState;
import ashui.core.render.Offscreen;
import ashui.css.Css;
import ashui.input.Pointer;
import ashui.layout.LayoutTree;
import ashui.reactive.Computed;
import ashui.reactive.Owner;
import rayde.workspace.session.Channel;
import rayde.workspace.session.EditorDocuments;
import rayde.workspace.session.SessionClient;

class SessionSelectionChecks {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;
	static function main():Void {
		ashui.theme.ThemeState.init(ashui.theme.themes.DefaultTheme.bundle(), Dark);
		var wire = new SelectionChannel(), client = SessionClient.over(wire), state = new CodeEditorState();
		var text = "first line\nsecond line\nthird line\nfourth line", file = "/work/a.hx";
		state.value.set(text);
		var editor:CodeEditor = null;
		var docs = new EditorDocuments(client, (_,_) -> {}, message -> { throw message; },
			_ -> {caret:editor.editing.caret.get(),anchor:editor.editing.anchor.get()}, _ -> false);
		docs.attach(file,state,text);
		var open = wire.sent.pop(true), tree = new LayoutTree(), stop:Void->Void = null;
		editor = Owner.root(tree, cleanup -> {
			stop = cleanup;
			return new CodeEditor({state:state,readOnly:Computed.make(() -> docs.readOnly(file))});
		});
		function frame():Void {
			client.drain(); docs.frame(); Offscreen.advance(.025);
			Css.setViewport(700,400); Css.update(); tree.flush(); tree.computeLayout(editor.node,700,400);
		}
		function move(offset:Int):Void {
			var box = editor.rectAt(offset);
			Pointer.move(tree,box.x + 1,box.y + box.height / 2);
		}
		function selection():Void {
			for (back in [false,true]) {
				move(back ? 33 : 0); Pointer.press(tree); frame();
				move(back ? 0 : 33); frame(); Pointer.release(tree); frame();
				check(editor.editing.selection() == text.substr(0,33),"Session readiness interrupted local selection");
				check(Css.query(tree,editor.node.id,".ui-code-selection").length == 3,"Session selection did not render");
			}
		}
		try {
			frame();
			check(docs.readOnly(file),"The test must hold document opening pending");
			selection(); check(wire.sent.pop(false) == null,"Selection sent RPC while document opening was pending");
			wire.reply({id:open.id,ok:true,result:{text:text,epoch:0,serial:0}});
			var end = haxe.Timer.stamp() + 3;
			while (docs.readOnly(file)) { frame(); if (haxe.Timer.stamp() > end) throw "Document did not become ready"; Sys.sleep(.001); }
			check(wire.sent.pop(true).op == "view.ready","Opening must acknowledge the projection");
			selection(); check(wire.sent.pop(false) == null,"Selection sent a document transaction");
			var disconnected = false, unsubscribe = client.subscribe(event -> if (event.ev == "session.disconnected") disconnected = true);
			wire.reply({ev:"session.disconnected",generation:1});
			end = haxe.Timer.stamp() + 3;
			while (!disconnected) { frame(); if (haxe.Timer.stamp() > end) throw "Disconnect was not received"; Sys.sleep(.001); }
			selection(); check(wire.sent.pop(false) == null && state.value.get() == text,"Offline selection depended on document synchronization");
			unsubscribe();
		} catch (error:Dynamic) { stop(); tree.dispose(); docs.close(); client.close(); throw error; }
		stop(); tree.dispose(); docs.close(); client.close();
		Sys.println("Session selection: both directions while opening, ready and offline, without document RPC");
	}
}

private class SelectionChannel implements Channel {
	final incoming = new sys.thread.Deque<String>();
	public final sent = new sys.thread.Deque<Dynamic>();
	public function new() {}
	public function reply(message:Dynamic):Void incoming.add(haxe.Json.stringify(message));
	public function sendText(text:String):Void {
		var message:Dynamic = haxe.Json.parse(text);
		if (message.op == "hello") reply({id:message.id,ok:true,root:"/work",name:"work",documentBridge:true,storageKey:"workspace"});
		else sent.add(message);
	}
	public function receive(seconds:Float):Null<String> { var next = incoming.pop(true); if (next == "closed") throw "closed"; return next; }
	public function close():Void incoming.add("closed");
}
