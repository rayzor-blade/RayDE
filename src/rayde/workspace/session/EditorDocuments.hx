package rayde.workspace.session;

import ashui.components.code.CodeEditorState;
import ashui.components.code.CodeHistory;
import ashui.components.code.CodeHistory.CodePatch;
import ashui.components.code.CodeHistory.CodeSelection;
import ashui.components.code.CodeTransaction;
import ashui.reactive.Signal;

/** Persistent document bindings. Futures complete on the receiver; text changes only on a UI frame. */
class EditorDocuments {
	final client:SessionClient;
	final bindings = new Map<String, EditorBinding>();
	final unsubscribe:Void->Void;
	final changed:(String, Bool)->Void;
	final failed:String->Void;
	final warning:String->Void;
	final selection:String->CodeSelection;
	final composing:String->Bool;
	final revision = Signal.make(0);
	final connected = Signal.make(true);
	var next = 0;
	var contextChanged = false;
	final prefix = Std.string(Std.random(0x3fffffff)) + ":";

	public function new(client:SessionClient, changed:(String, Bool)->Void, failed:String->Void, selection:String->CodeSelection, composing:String->Bool, ?warning:String->Void) {
		this.client = client; this.changed = changed; this.failed = failed; this.selection = selection; this.composing = composing;
		this.warning = warning == null ? failed : warning;
		unsubscribe = client.subscribe(event -> {
			if (event.ev == "session.disconnected") {
				connected.set(false);
				if (event.code == "workspace-changed" && !contextChanged) {
					contextChanged = true;
					this.warning(event.message);
				}
			}
			if (event.ev == "session.connected") connected.set(true);
			if (event.ev != "view.remote" && event.ev != "view.error" && event.ev != "view.status") return;
			for (binding in bindings) if (binding.handle == event.handle) {
				if(event.ev=="view.status")binding.statusPending=event.message;else if (event.ev == "view.error") binding.fail(event.message, event.code != "workspace-changed"); else binding.remote = event;
				break;
			}
		});
	}

	public function attach(file:String, state:CodeEditorState, disk:String):Void {
		if (bindings.exists(file)) return;
		var binding:EditorBinding = null;
		binding = new EditorBinding(client, prefix + next++, file, state, disk, local -> changed(binding.file, local), failed,
			() -> selection(binding.file), () -> composing(binding.file));
		bindings.set(file,binding);
		revision.set(revision.get() + 1);
	}
	/** The page keeps the same handle and undo owner after its confirmed filesystem move. */
	public function remap(from:String,to:String):Void {
		var moved = rayde.files.FileOps.moved([for (file in bindings.keys()) file],from,to);
		var retained = [for (old => next in moved) {file:next,binding:bindings.get(old)}];
		for (old in moved.keys()) bindings.remove(old);
		for (entry in retained) { entry.binding.file = entry.file; bindings.set(entry.file,entry.binding); }
		if (retained.length > 0) revision.set(revision.get() + 1);
	}
	public function owns(file:String):Bool {var binding=bindings.get(file);return binding!=null&&binding.active;}
	public function refresh(file:String):Void {var binding=bindings.get(file);if(binding!=null&&binding.active)binding.refresh();}
	public function readOnly(file:String):Bool { revision.get(); var binding = bindings.get(file); return binding != null && (binding.blocked.get() || binding.moving.get()); }
	/** Hold projection callbacks until the workbench has remapped every path-based owner. */
	public function hold(from:String):Void->Void {
		var held = [for (file => binding in bindings) if (rayde.files.FileOps.inside(from,file)) binding];
		for (binding in held) { binding.acceptBuffer(); binding.moving.set(true); }
		return () -> { for (binding in held) { binding.moving.set(false); binding.acceptBuffer(); } };
	}
	public function message(file:String):String {
		revision.get(); var binding = bindings.get(file);
		return binding == null ? "" : binding.failure.get() != "" ? "Document sync paused" : binding.moving.get() ? "Moving document…" : binding.blocked.get() ? "Synchronizing document…" : !connected.get() ? "Offline · edits kept locally" : binding.status.get();
	}
	public function acceptBuffer(file:String):Void { var binding = bindings.get(file); if (binding != null) binding.acceptBuffer(); }
	public function pause(message:String):Void for (binding in bindings) binding.fail(message,false);
	public function frame():Void for (binding in bindings) binding.frame();
	public function save(file:String, done:(Null<String>, String, String)->Void):Bool {
		var binding = bindings.get(file); if (binding == null || !binding.active) return false;
		binding.save(done);
		return true;
	}
	public function release(file:String):Void { var binding = bindings.get(file); if (binding != null) { binding.dispose(); bindings.remove(file); revision.set(revision.get() + 1); } }
	public function close():Void { unsubscribe(); for (binding in bindings) binding.dispose(); bindings.clear(); }
}

private class EditorBinding {
	public var active(default,null)=true;
	public final handle:String;
	public final blocked = Signal.make(true);
	public final failure = Signal.make("");
	public final moving = Signal.make(false);
	public var remote:Dynamic;
	public var statusPending:Null<String>;
	public final status=Signal.make("");
	final client:SessionClient;
	final state:CodeEditorState;
	public var file:String;
	var disk:String;
	var initial:String;
	final changed:Bool->Void;
	final failed:String->Void;
	final selection:Void->CodeSelection;
	final composing:Void->Bool;
	var pending:Null<ash.Future<Dynamic>>;
	var saving:Null<{future:ash.Future<Dynamic>, text:String, done:(Null<String>, String, String)->Void}>;
	var opening = true;
	var closed = false;
	var broken = false;
	var known:String;
	var epoch = 0;
	var serial = 0;

	public function new(client:SessionClient, handle:String, file:String, state:CodeEditorState, disk:String,
		changed:Bool->Void, failed:String->Void, selection:Void->CodeSelection, composing:Void->Bool) {
		this.client = client; this.handle = handle; this.file = file; this.state = state; this.disk = disk;
		this.changed = changed; this.failed = failed; this.selection = selection; this.composing = composing;
		known = initial = state.value.get();
		if (state.onTransaction != null || state.onUndo != null) throw "This document already belongs to a collaboration session.";
		state.onTransaction = transaction;
		state.onUndo = undo;
		pending = client.requestAsync("view.open", {handle:handle, path:rayde.files.FileOps.relative(client.root, file)});
	}

	function notify(op:String, params:Dynamic):Void {
		Reflect.setField(params, "handle", handle);
		try client.notify(op, params) catch (error:Dynamic) fail(Std.string(error));
	}
	function transaction(edit:CodeTransaction):Void {
		if (moving.get()) throw "Wait for this document to finish moving.";
		if (blocked.get() || edit.before != known) { fail("The shared document changed before this edit could be applied."); throw "Wait for document synchronization."; }
		known = edit.after;
		notify("view.edit", {epoch:epoch, serial:++serial, parts:edit.parts});
	}
	public function acceptBuffer():Void {
		if (!active || closed || broken || moving.get() || state.value.get() == known) return;
		var next = state.value.get(), position = selection();
		transaction({before:known, after:next, parts:CodeHistory.difference(known,next), selection:position, next:position});
	}
	public function refresh():Void {if(!opening&&!closed&&!broken)notify("view.sync",{});}
	function undo(redo:Bool):Void {
		if (blocked.get() || moving.get() || closed) return;
		acceptBuffer(); blocked.set(true);
		pending = client.requestAsync("view.undo", {handle:handle, epoch:epoch, serial:++serial, redo:redo});
	}
	public function save(done:(Null<String>, String, String)->Void):Void {
		if (blocked.get() || moving.get()) throw "Wait for this document to finish synchronizing before saving.";
		if (saving != null) throw "This document is already being saved.";
		acceptBuffer();
		saving = {future:client.requestAsync("view.save", {handle:handle}), text:known, done:done};
	}
	public function fail(message:String, report = true):Void {
		if (closed || broken) return;
		broken = true; failure.set(message); blocked.set(true);
		if (saving != null) { var completed = saving; saving = null; completed.done(message,completed.text,file); }
		if (report) failed(haxe.io.Path.withoutDirectory(file) + ": " + message);
	}
	function apply(message:Dynamic):Void {
		var position = selection(), parts:Array<CodePatch> = message.parts == null ? [] : cast message.parts;
		function moved(offset:Int):Int {
			var shift = 0;
			for (part in parts) {
				if (offset < part.from) break;
				if (offset <= part.from + part.removed.length) return part.from + shift + part.inserted.length;
				shift += part.inserted.length - part.removed.length;
			}
			return offset + shift;
		}
		known = message.text;
		state.applyRemote(known, {caret:moved(position.caret), anchor:moved(position.anchor)});
	}
	public function frame():Void {
		if(statusPending!=null){status.set(statusPending);statusPending=null;}
		if (closed || broken || moving.get()) return;
		if (saving != null && (saving.future.isReady() || saving.future.isRejected())) {
			var completed = saving; saving = null;
			var error:Null<String> = null;
			try {var envelope:Dynamic=completed.future.await();var result:Dynamic=envelope==null?null:Reflect.hasField(envelope,"result")?envelope.result:envelope;if(result!=null&&Std.isOfType(result.text,String))completed.text=result.text;} catch (failure:Dynamic) error = Std.string(failure);
			completed.done(error,completed.text,file);
			if (closed) return;
		}
		if (pending != null) {
			if (!pending.isReady() && !pending.isRejected()) return;
			var result:Dynamic;
			try result = pending.await().result catch (error:Dynamic) { pending = null; fail(Std.string(error)); return; }
			pending = null;
			if(opening&&result!=null&&result.passthrough==true){
				opening=false;active=false;blocked.set(false);state.onTransaction=null;state.onUndo=null;
				status.set(Std.isOfType(result.syncMessage,String)?result.syncMessage:"");return;
			}
			if (result == null || !Std.isOfType(result.text,String)) { fail("The workspace returned an invalid document."); return; }
			if(Std.isOfType(result.syncMessage,String))status.set(result.syncMessage);
			var previous = state.value.get();
			if (opening) {
				state.history.clear();
				opening = false; known = result.text; state.applyRemote(known);
				blocked.set(false); notify("view.ready", {});
				if (initial != disk && initial != known) {
					if (known == disk) {
						var position = selection();
						transaction({before:known, after:initial, parts:CodeHistory.difference(known,initial), selection:position, next:position});
						state.applyRemote(initial); changed(true);
					} else failed("Workspace changes loaded for " + haxe.io.Path.withoutDirectory(file) + ". Your recovered text is still in Local History.");
				}
				if (result.dirty == true) changed(true);
				else if (previous != state.value.get()) changed(false);
				initial = disk = "";
			} else {
				apply(result); blocked.set(false);
				if (previous != known) changed(true);
			}
		}
		if (remote != null && !composing()) {
			var message = remote; remote = null;
			var accept = message.serial == serial;
			if (accept) {
				var previous = state.value.get(); apply(message); epoch = message.epoch;
				if (previous != known) changed(message.dirty==true);
			}
			notify("view.ack", {epoch:message.epoch, accept:accept});
		}
	}
	public function dispose():Void {
		if (closed) return;
		closed = true;
		if(active){state.onTransaction = null; state.onUndo = null; state.history.clear();}
		notify("view.close", {}); pending = null; saving = null; remote = null;
	}
}
