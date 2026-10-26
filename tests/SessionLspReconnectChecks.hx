import haxe.crypto.Base64;
import haxe.io.Bytes;
import rayde.lang.LanguageServers;
import rayde.lang.LspFrames;
import rayde.workspace.Procs;
import rayde.workspace.session.Channel;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.SessionLauncher;

@:access(rayde.workspace.session.SessionLauncher)
class SessionLspReconnectChecks {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;
	static function rejected(future:ash.Future<Dynamic>):Bool { try future.await() catch (_:Dynamic) return true; return false; }
	static function main():Void {
		var previous = Procs.current, wire = new ReconnectingChannel(), session = SessionClient.over(wire), launcher = new SessionLauncher(session);
		Procs.current = launcher;
		var compiler = new rayde.lang.CompilerServer(), refused = false;
		try compiler.ensure() catch (_:Dynamic) refused = true;
		check(refused && !compiler.canConnect() && wire.starts() == 0,"remote code inspection must not probe the editor's localhost sockets");
		var servers = new LanguageServers("/work");
		servers.register("test",{id:"test",languages:["haxe"],fileExtensions:[".hx"],lazy:true,transport:{kind:"stdio",command:"test"}},(_,_) -> {});
		function pump():Void { session.drain(); servers.tick(); }
		function wait(ready:Void->Bool):Void {
			var end = haxe.Timer.stamp()+5;
			while (!ready()) { pump(); if (haxe.Timer.stamp()>end) throw "Reconnect did not settle"; Sys.sleep(.001); }
			pump();
		}
		servers.sync("/work/Main.hx","class Main {}");
		wait(() -> servers.client("/work/Main.hx").state == "ready" && wire.text() == "class Main {}");
		var old = launcher.running.get(1);
		wire.reply({ev:"session.disconnected",generation:1});
		wait(() -> !session.isOnline());
		check(servers.status("/work/Main.hx").state == "disconnected" && !servers.busy(),"offline LSP must sleep without consuming restart attempts");
		servers.sync("/work/Main.hx","class Main { // offline\n}");
		for (_ in 0...100) pump();
		check(wire.starts() == 1,"offline edits must not launch processes");
		wire.reply({ev:"session.connected",generation:1});
		wait(() -> session.isOnline() && servers.status("/work/Main.hx").state == "ready" && wire.text().indexOf("offline") >= 0);
		check(wire.starts() == 2,"one restart must replay unsaved text");
		check(rejected(old.killAsync()) && rejected(old.writeAsync("stale")),"old handles must reject after PID reuse");
		check(wire.kills() == 0,"stale cleanup cannot kill the replacement process");

		wire.reply({ev:"session.disconnected",generation:2}); wait(() -> !session.isOnline());
		servers.control("test","stop");
		wire.reply({ev:"session.connected",generation:2}); wait(session.isOnline);
		check(servers.status("/work/Main.hx").state == "stopped" && wire.starts() == 2,"an explicit offline Stop must survive reconnect");
		servers.release("test");
		servers.register("test",{id:"test",languages:["haxe"],fileExtensions:[".hx"],lazy:true,transport:{kind:"stdio",command:"test"}},(_,_) -> {});
		servers.sync("/work/Main.hx","class Main { // offline\n}");
		pump();
		check(servers.status("/work/Main.hx").state == "stopped" && wire.starts() == 2,"extension re-registration must preserve an explicit Stop");
		servers.control("test","start");
		wait(() -> servers.status("/work/Main.hx").state == "ready" && wire.starts() == 3);
		wire.reply({ev:"session.disconnected",generation:3}); wait(() -> !session.isOnline());
		servers.retain([]);
		wire.reply({ev:"session.connected",generation:3}); wait(session.isOnline);
		check(servers.status("").state == "idle" && wire.starts() == 3,"a lazy server with no documents stays asleep after reconnect");
		servers.dispose(); session.close(); Procs.current = previous;
		Sys.println("session LSP recovery: offline sleep and edits, replay, PID fencing, offline Stop and lazy Welcome passed");
	}
}

private class ReconnectingChannel implements Channel {
	final incoming = new sys.thread.Deque<String>();
	final mutex = new sys.thread.Mutex();
	var spawned = 0;
	var killed = 0;
	var content = "";
	var frames:LspFrames;
	public function new() {}
	public function starts():Int { mutex.acquire(); var value = spawned; mutex.release(); return value; }
	public function kills():Int { mutex.acquire(); var value = killed; mutex.release(); return value; }
	public function text():String { mutex.acquire(); var value = content; mutex.release(); return value; }
	public function reply(value:Dynamic):Void incoming.add(haxe.Json.stringify(value));
	function output(message:Dynamic):Void reply({ev:"proc.out",pid:1,stream:"stdout",data:Base64.encode(LspFrames.frame(message))});
	public function sendText(text:String):Void {
		var request:Dynamic = haxe.Json.parse(text);
		switch (request.op:String) {
			case "hello": reply({id:request.id,ok:true,root:"/work",name:"work",exec:true});
			case "proc.spawn":
				mutex.acquire(); spawned++; content = ""; mutex.release();
				frames = new LspFrames((message,_) -> {
					if (message.method == "initialize") output({jsonrpc:"2.0",id:message.id,result:{capabilities:{hoverProvider:true,textDocumentSync:1}}});
					else if (message.method == "shutdown") output({jsonrpc:"2.0",id:message.id,result:null});
					else if (message.method == "textDocument/didOpen" || message.method == "textDocument/didChange") {
						mutex.acquire(); content = message.method == "textDocument/didOpen" ? message.params.textDocument.text : message.params.contentChanges[0].text; mutex.release();
					}
				});
				reply({id:request.id,ok:true,pid:1});
			case "proc.write":
				var bytes = Base64.decode(request.data); frames.push(bytes,bytes.length); reply({id:request.id,ok:true});
			case "proc.kill": mutex.acquire(); killed++; mutex.release(); reply({id:request.id,ok:true});
			case _: reply({id:request.id,ok:true});
		}
	}
	public function receive(seconds:Float):Null<String> { var text = incoming.pop(true); if (text == "closed") throw "closed"; return text; }
	public function close():Void incoming.add("closed");
}
