package rayde.jam;

import ashui.components.code.CodeEditorState;
import ashui.components.code.CodeHistory;
import ashui.components.code.CodeHistory.CodeSelection;
import ashui.components.code.CodeTransaction;
import ashui.components.code.CodeTransaction.CodePeer;
import ashui.reactive.Signal;

typedef JamViewport = {top:Int, offset:Float, x:Float};
typedef JamPosition = {id:String, name:String, caret:Int, anchor:Int, view:Null<JamViewport>};

/** A single explicitly shared document; view mounting never controls the CRDT lifetime. */
class JamSession {
	public final file:String;
	public final host:Bool;
	public var initialText(default,null):String;
	public final comparisonId = "jam:" + haxe.crypto.Sha256.encode(Std.string(Sys.time()) + ":" + Std.random(0x3fffffff)).substr(0,16);
	public var changeAuthor(default,null):Null<String>;
	final localName:String;
	public final status = Signal.make("connecting");
	public final invite = Signal.make("");
	public final people = Signal.make(([] : Array<{id:String,name:String}>));
	public final initialized = Signal.make(false);
	public final failure = Signal.make("");
	public final recoveryStatus = Signal.make("saving locally");
	public final durableHost = Signal.make(false);
	public final synced = Signal.make(false);
	public final following = Signal.make("");
	public final positions = Signal.make(([] : Array<JamPosition>));
	var viewport:Null<JamViewport>;
	final seeded:Bool;
	final state:CodeEditorState;
	final changed:Void->Void;
	var document = -1;
	var transport = -1;
	var peer = "";
	var serial = 0;
	var known:String;
	var selection:CodeSelection = {caret:0,anchor:0};
	final cursors = new Map<String,Dynamic>();
	public var closed(default,null) = false;

	public function new(file:String,state:CodeEditorState,host:Bool,name:String,invitation:String,changed:Void->Void,recovery:String,restore:Bool=false) {
		this.file=file; this.state=state; this.host=host; this.changed=changed; known=state.value.get(); initialText=known; localName=name;
		seeded=host && !restore;
		document=NativeJam.document(seeded ? state.value.get() : "");
		try {
			var snapshot=NativeJam.call(document,{op:"snapshot"});
			transport=NativeJam.open({host:host,invite:invitation,name:name,file:haxe.io.Path.withoutDirectory(file),state:snapshot.state,document_id:seeded ? snapshot.document_id : "",recovery:recovery,restore:restore});
		} catch (error:Dynamic) { NativeJam.closeDocument(document); document=-1; throw error; }
		state.history.clear(); state.onTransaction=transaction; state.onUndo=undo;
	}
	public function canWake():Bool return transport >= 0 && NativeJam.canWake(transport);
	public function pending():Bool return transport >= 0 && NativeJam.pending(transport);
	public function editable():Bool return initialized.get() && failure.get() == "" && !closed;

	function transaction(edit:CodeTransaction):Void {
		if (closed || edit.parts.length == 0) return;
		stopFollowing();
		try {
			if (edit.before != known) throw "Jam document and editor are out of sync";
			var result=NativeJam.call(document,{op:"edit",parts:edit.parts});
			known=edit.after; selection=edit.next; changeAuthor=localName;
			publish(result.update);
			refreshCursors();
		} catch (error:Dynamic) fail(Std.string(error));
	}
	/** Also covers buffer writes made by extensions while the presentation is inactive. */
	public function acceptBuffer():Void {
		var before=known, after=state.value.get();
		if (before == after) return;
		transaction({before:before,after:after,parts:CodeHistory.difference(before,after),selection:selection,next:selection});
	}
	function publish(update:String):Void {
		if (!closed && transport >= 0) {
			recoveryStatus.set("saving locally"); synced.set(false);
			if (!NativeJam.send(transport,{t:"sync",id:++serial,update:update})) fail("Jam could not queue an update; leave and rejoin");
		}
	}
	function undo(redo:Bool):Void {
		if (!editable()) return;
		stopFollowing();
		try {
			var result=NativeJam.call(document,{op:"undo",redo:redo});
			selection={caret:Std.int(Math.min(selection.caret,result.text.length)),anchor:Std.int(Math.min(selection.anchor,result.text.length))};
			known=result.text; changeAuthor=localName; state.applyRemote(result.text,selection); publish(result.update); changed(); refreshCursors();
		} catch (error:Dynamic) fail(Std.string(error));
	}
	public function remember(caret:Int,anchor:Int,?view:JamViewport):Void {
		selection={caret:caret,anchor:anchor};
		if (view != null) viewport=view;
	}
	public function isSelf(id:String):Bool return peer == id;
	public function positionOf(id:String):Null<JamPosition> return Lambda.find(positions.get(),p -> p.id == id);
	public function follow(id:String):Bool {
		if (status.get() != "connected" || failure.get() != "" || id == peer || positionOf(id) == null) return false;
		following.set(id); return true;
	}
	public function stopFollowing():Void following.set("");
	public function moved(caret:Int,anchor:Int):Void {
		remember(caret,anchor);
		if (!editable() || status.get() != "connected" || following.get() != "") return;
		try {
			var positions=NativeJam.call(document,{op:"position",caret:caret,anchor:anchor});
			var view:Dynamic=null;
			if (viewport != null) try {
				var top=NativeJam.call(document,{op:"position",caret:viewport.top,anchor:viewport.top});
				view={top:top.caret,offset:viewport.offset,x:viewport.x};
			} catch (_:Dynamic) {}
			NativeJam.send(transport,{t:"presence",caret:positions.caret,anchor:positions.anchor,view:view});
		} catch (error:Dynamic) fail(Std.string(error));
	}
	public function poll():Void {
		if (closed || transport < 0) return;
		var messages=NativeJam.poll(transport);
		if (messages == null) return;
		try for (message in messages) switch Std.string(message.t) {
			case "hosting": invite.set(message.invite);
			case "identity": peer=message.peer;
			case "restored":
				if (message.file != haxe.io.Path.withoutDirectory(file)) throw "This checkpoint belongs to a different document";
				apply(message.state); initialized.set(true); recoveryStatus.set("saved locally"); status.set("reconnecting");
			case "welcome":
				if (message.v != 3 || message.file != haxe.io.Path.withoutDirectory(file)) throw "The invitation shares a different document; open " + Std.string(message.file) + " and join again";
				apply(message.state); durableHost.set(message.durable == true);
				publish(NativeJam.call(document,{op:"diff",vector:message.vector}).update);
				initialized.set(true); status.set("connected"); moved(selection.caret,selection.anchor);
			case "update":
				var person = Lambda.find(people.get(), p -> p.id == message.peer);
				apply(message.update, person == null ? null : person.name);
			case "cursor": if (message.peer != peer) { cursors.set(message.peer,message); refreshCursors(); }
			case "peers":
				people.set(cast message.list);
				for (id in cursors.keys()) if (!Lambda.exists(people.get(),p -> p.id == id)) cursors.remove(id);
				if (!Lambda.exists(people.get(),p -> p.id == following.get())) stopFollowing();
				refreshCursors();
			case "reconnecting" | "paused": status.set(message.t); disconnected();
			case "failed": fail(message.message);
			case "room_closed": fail("The host ended this Jam");
			case "locally_saved": if (message.id == serial) recoveryStatus.set("saved locally");
			case "checkpointed": if (message.id == serial) recoveryStatus.set("saved locally");
			case "ack": if (message.id == serial) synced.set(true);
			default: throw "Unexpected Jam event";
		} catch (error:Dynamic) fail(Std.string(error));
	}
	function apply(update:String, ?author:String):Void {
		var before=state.value.get();
		var current:CodeSelection=initialized.get() || seeded ? selection : {caret:0,anchor:0};
		var result=NativeJam.call(document,{op:"apply",update:update,caret:current.caret,anchor:current.anchor});
		selection={caret:result.caret,anchor:result.anchor};
		known=result.text; changeAuthor=author ?? "Jam sync";
		if (!initialized.get()) initialText=result.text;
		state.applyRemote(result.text,selection);
		if (before != result.text) changed();
		refreshCursors();
	}
	function refreshCursors():Void {
		var marks:Array<CodePeer>=[], resolved:Array<JamPosition>=[];
		for (person in people.get()) if (person.id != peer && cursors.exists(person.id)) {
			var cursor=cursors.get(person.id);
			try {
				var position=NativeJam.call(document,{op:"resolve",caret:cursor.caret,anchor:cursor.anchor});
				var color=0; for (i in 0...person.id.length) color=(color+person.id.charCodeAt(i))%4;
				marks.push({id:person.id,name:person.name,caret:position.caret,anchor:position.anchor,color:color});
				var view:Null<JamViewport>=null;
				if (cursor.view != null) {
					var top=NativeJam.call(document,{op:"resolve",caret:cursor.view.top,anchor:cursor.view.top});
					view={top:top.caret,offset:cursor.view.offset,x:cursor.view.x};
				}
				resolved.push({id:person.id,name:person.name,caret:position.caret,anchor:position.anchor,view:view});
			} catch (_:Dynamic) {}
		}
		state.peers.set(marks); positions.set(resolved);
	}
	public function checkpoint():Void {
		if (transport >= 0) {
			recoveryStatus.set("saving locally");
			if (!NativeJam.send(transport,{t:"checkpoint",id:serial})) fail("Jam could not queue a checkpoint");
		}
	}
	public function pause(paused:Bool):Void { if (transport >= 0) NativeJam.send(transport,{t:"pause",paused:paused}); }
	function disconnected():Void {
		stopFollowing(); synced.set(false); cursors.clear(); positions.set([]); people.set([]); state.peers.set([]);
	}
	function fail(message:String):Void {
		failure.set(message); status.set("failed"); disconnected();
		if (transport >= 0) NativeJam.closeSession(transport); transport=-1;
	}
	public function dispose():Void {
		if (closed) return;
		closed=true; state.onTransaction=null; state.onUndo=null; state.peers.set([]); state.history.clear();
		if (transport >= 0) NativeJam.closeSession(transport); transport=-1;
		if (document >= 0) NativeJam.closeDocument(document); document=-1;
		disconnected(); invite.set(""); status.set("closed");
	}
}
