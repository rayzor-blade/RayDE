package rayde.ui;

import ashui.components.code.CodeHighlighter;
import ashui.reactive.Signal;
import rayde.run.Worker;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.SessionClient.SessionFailure;

private typedef Request = {source:String};
private typedef Reply = {source:String,tokens:Dynamic,retry:Bool,error:Null<String>};

/** A view owns one debounced syntax query; completed snapshots cross into the UI only at a frame boundary. */
class SessionSyntax {
	static var next = 0;
	public final highlighter = Signal.make((null:Null<CodeHighlighter>));
	final source:Signal<String>;
	final client:SessionClient;
	final key:String;
	final worker:Worker<Request,Reply>;
	var timer:Null<ashui.animation.AnimationScheduler.Timer>;
	var disposed = false;
	var retries = 0;

	public function new(client:SessionClient,file:String,source:Signal<String>) {
		this.source = source; this.client = client; key = "editor-syntax-" + next++;
		var remote = client, job = key, name = haxe.io.Path.withoutDirectory(file);
		worker = new Worker<Request,Reply>((request,cancelled) -> {
			if (cancelled()) return {source:request.source,tokens:null,retry:false,error:null};
			try {
				var response = remote.request("syntax.highlight",{key:job,file:name,source:request.source},10);
				return {source:request.source,tokens:response.tokens,retry:false,error:null};
			} catch (error:Dynamic) {
				var failure:Null<SessionFailure> = Std.isOfType(error,SessionFailure) ? cast error : null;
				return {source:request.source,tokens:null,retry:failure != null && failure.code == "busy",error:failure != null && failure.code == "cancelled" ? null : Std.string(error)};
			}
		},ashui.core.Work.notify);
		new ashui.reactive.Watch(source.get,text -> {
			retries = 0; worker.cancel("source"); cancelRemote(); schedule(text,.12);
		});
		var tree = ashui.reactive.Owner.current.tree;
		var receive:ashui.layout.LayoutTree->Void = current -> {
			if (current != tree || disposed) return;
			for (result in worker.poll()) {
				var value = result.value;
				if (result.error != null) { highlighter.set(null); Sys.println('Syntax for "$name": ' + result.error); continue; }
				if (value == null || value.source != source.get()) continue;
				if (value.retry && retries++ < 5) { schedule(value.source,.2); continue; }
				if (value.error != null) { highlighter.set(null); Sys.println('Syntax for "$name": ' + value.error); continue; }
				highlighter.set(value.tokens == null ? null : new SnapshotSyntax(value.tokens));
			}
		};
		ashui.layout.LayoutTree.flushHooks.push(receive);
		var unsubscribe = client.subscribe(event -> {
			if (disposed) return;
			if (event.ev == "session.connected") { retries = 0; schedule(source.get(),.12); }
			else if (event.ev == "session.disconnected") worker.cancel("source");
		});
		ashui.reactive.Owner.onCleanup(() -> {
			disposed = true; if (timer != null) timer.cancel(); worker.dispose(); cancelRemote(); unsubscribe();
			for (i in 0...ashui.layout.LayoutTree.flushHooks.length) if (Reflect.compareMethods(ashui.layout.LayoutTree.flushHooks[i],receive)) { ashui.layout.LayoutTree.flushHooks.splice(i,1); break; }
		});
	}

	function cancelRemote():Void if (client.isOnline()) try client.notify("syntax.cancel",{key:key}) catch (_:Dynamic) {}
	function schedule(text:String,delay:Float):Void {
		if (timer != null) { timer.cancel(); timer = null; }
		if (text.length > 2*1024*1024) { highlighter.set(null); return; }
		timer = ashui.animation.AnimationScheduler.main.after(delay,() -> { timer = null; if (!disposed && client.isOnline()) worker.submit("source",{source:text}); });
	}
}

/** The document packs each row once; the transient response table is released as it is consumed. */
private class SnapshotSyntax implements CodeHighlighter {
	final lines:Array<Null<Array<Dynamic>>>;
	public function new(lines:Dynamic) this.lines = lines;
	public function highlight(line:String,state:String):CodeHighlight {
		var index = (state == "" ? 0 : Std.parseInt(state)) ?? 0;
		var input = index >= lines.length ? null : lines[index];
		if (index < lines.length) lines[index] = null;
		var tokens:Array<CodeToken> = input == null ? [] : [for (token in input) {from:Std.int(token.from),to:Std.int(token.to),kind:cast Std.string(token.kind)}];
		if (index == lines.length-1) lines.resize(0);
		return {tokens:tokens,state:Std.string(index+1)};
	}
}
