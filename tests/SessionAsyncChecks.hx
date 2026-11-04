import ash.Future;
import haxe.crypto.Base64;
import haxe.io.Bytes;
import rayde.workspace.session.Channel;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.SessionLauncher;

class SessionAsyncChecks {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;
	static function rejected(future:Future<Dynamic>):Bool {
		try future.await() catch (_:Dynamic) return true;
		return false;
	}
	static function main():Void {
		var wire = new TestChannel(), client = SessionClient.over(wire);
		check(client.isOnline(), "A native hello without an online field must remain connected");
		var pending = [for (i in 0...128) client.requestAsync("echo", {value:i})];
		var requests = [for (_ in pending) wire.sent.pop(true)];
		requests.reverse();
		for (request in requests) wire.reply({id:request.id,ok:true,value:request.value});
		for (i => future in pending) check(future.await().value == i, "answers must complete their own futures");

		wire.pause = true;
		var blocked = client.requestAsync("blocked", null, .05);
		wire.entered.wait();
		check(rejected(blocked), "a blocked writer must not stop deadlines or the caller");
		wire.release.release();
		wire.pause = false;
		var refused = client.requestAsync("refused");
		var request = wire.sent.pop(true);
		wire.reply({id:request.id,ok:false,code:"denied",message:"Denied"});
		check(rejected(refused), "remote errors must reject the request");

		var launcher = new SessionLauncher(client);
		wire.program = true;
		var process = launcher.startAsync("instant", []).await();
		check(process.stdout.readAll().toString() == "first\nlast\n", "output before spawn reply must be preserved");
		check(process.exitCode() == 0, "an early exit must settle program readers");
		process.close();
		wire.program = false;

		var waiting = client.requestAsync("never");
		wire.sent.pop(true);
		client.close();
		check(rejected(waiting), "close must reject pending requests");
		check(rejected(client.requestAsync("closed")), "requests after close must reject immediately");
		wire = new TestChannel(true); client = SessionClient.over(wire);
		check(client.deferred && !client.isOnline() && !client.exec, "A deferred hello must leave compute offline");
		var observed = false;
		client.subscribe(event -> if (event.ev == "session.connected") observed = client.isOnline() && client.exec && client.extensionsRoot == "/installed/extensions" && client.readOnly("/installed/extensions/git"));
		wire.reply({ev:"session.connected",generation:1,capabilities:{root:"/work",storageKey:"draft",exec:true,syntax:true,terminal:true,
			extensions:{host:"/installed/extension-host",root:"/installed/extensions"},readRoots:[{id:"extensions",path:"/installed/extensions"}]}});
		var end = haxe.Timer.stamp() + 2;
		while (!observed && haxe.Timer.stamp() < end) {client.drain(); Sys.sleep(.001);}
		check(observed, "Deferred capabilities must be visible before connected listeners run");
		check(client.storageKey == "draft" && client.terminal, "Attachment changed the recovery identity or lost terminal support");
		client.close();
		Sys.println("Session futures: ordering, deadlines, errors, early process output and close passed");
	}
}

private class TestChannel implements Channel {
	final incoming = new sys.thread.Deque<String>();
	public final sent = new sys.thread.Deque<Dynamic>();
	public final entered = new sys.thread.Lock();
	public final release = new sys.thread.Lock();
	public var pause = false;
	public var program = false;
	final deferred:Bool;
	public function new(deferred = false) {this.deferred = deferred;}
	public function reply(value:Dynamic):Void incoming.add(haxe.Json.stringify(value));
	public function sendText(text:String):Void {
		var request:Dynamic = haxe.Json.parse(text);
		if (request.op == "hello") {
			var hello:Dynamic = {id:request.id,ok:true,root:"/work",name:"work",exec:!deferred};
			if (deferred) {hello.online = false; hello.deferred = true; hello.storageKey = "draft";}
			reply(hello); return;
		}
		if (pause) { entered.release(); release.wait(); return; }
		if (program && request.op == "proc.spawn") {
			reply({ev:"proc.out",pid:1,stream:"stdout",data:Base64.encode(Bytes.ofString("first\n"))});
			reply({ev:"proc.out",pid:1,stream:"stdout",data:Base64.encode(Bytes.ofString("last\n"))});
			reply({ev:"proc.exit",pid:1,code:0});
			reply({id:request.id,ok:true,pid:1}); return;
		}
		sent.add(request);
	}
	public function receive(seconds:Float):Null<String> {
		var text = incoming.pop(true); if (text == "closed") throw "closed"; return text;
	}
	public function close():Void incoming.add("closed");
}
