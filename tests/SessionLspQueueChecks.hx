import haxe.io.BytesBuffer;
import haxe.crypto.Base64;
import rayde.lang.LspFrames;
import rayde.lang.SessionLspTransport;
import rayde.workspace.session.Channel;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.SessionLauncher;

@:access(rayde.workspace.session.SessionLauncher)
class SessionLspQueueChecks {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;
	static function wait(ready:Void->Bool):Void {
		var end = haxe.Timer.stamp()+3;
		while (!ready()) { if (haxe.Timer.stamp() > end) throw "Remote transport did not settle"; Sys.sleep(.001); }
	}
	static function main():Void {
		var wire = new LspChannel(), client = SessionClient.over(wire), launcher = new SessionLauncher(client);
		var transport = new SessionLspTransport(launcher,{command:"delayed",cwd:"/work",args:[]});
		var spawn = wire.sent.pop(true), count = 0;
		for (_ in 0...1100) if (transport.send({jsonrpc:"2.0",method:"test"})) count++;
		check(count == 1024,"the pre-start input queue is bounded without blocking its caller");
		transport.close();
		wire.reply({id:spawn.id,ok:true,pid:7});
		check(wire.killed.wait(3),"closing during launch kills the late process");
		wait(() -> Lambda.count(launcher.running) == 0);
		check(!transport.pending() && !transport.send({}),"late startup events do not revive a closed transport");
		client.close();

		wire = new LspChannel(); client = SessionClient.over(wire); launcher = new SessionLauncher(client);
		var wake = new sys.thread.Lock(); client.onWake = () -> wake.release();
		transport = new SessionLspTransport(launcher,{command:"noisy",cwd:"/work",args:[]});
		spawn = wire.sent.pop(true); wire.reply({id:spawn.id,ok:true,pid:8});
		wait(transport.pending); transport.poll();
		check(transport.canWake() && wake.wait(.1),"stream parsing can wake a sleeping UI");
		var output = new BytesBuffer(), packet = LspFrames.frame({jsonrpc:"2.0",method:"test/notification"});
		for (_ in 0...2100) output.add(packet);
		wire.reply({ev:"proc.out",pid:8,stream:"stdout",data:Base64.encode(output.getBytes())});
		check(wire.killed.wait(3),"a noisy server is stopped when its event queue fills");
		var events = transport.poll();
		check(events != null && Lambda.exists(events,event -> event.t == "error"),"overflow preserves a terminal error event");
		wait(() -> Lambda.count(launcher.running) == 0);
		transport.close(); client.close();

		wire = new LspChannel(); client = SessionClient.over(wire); launcher = new SessionLauncher(client);
		var obsolete = launcher.startAsync("old",[]), oldSpawn = wire.sent.pop(true);
		wire.reply({ev:"session.disconnected",generation:1}); wait(() -> !client.isOnline());
		wire.reply({ev:"session.connected",generation:1}); wait(client.isOnline);
		var replacement = launcher.startAsync("new",[]), newSpawn = wire.sent.pop(true);
		wire.reply({ev:"proc.out",pid:9,stream:"stdout",data:Base64.encode(haxe.io.Bytes.ofString("new output"))});
		wire.reply({id:oldSpawn.id,ok:true,pid:9});
		var refused = false; try obsolete.await() catch (_:Dynamic) refused = true;
		check(refused,"a spawn reply from an old connection must not create a live handle");
		wire.reply({id:newSpawn.id,ok:true,pid:9});
		var program = replacement.await(), bytes = haxe.io.Bytes.alloc(10);
		check(program.stdout.readBytes(bytes,0,10) == 10 && bytes.toString() == "new output","a stale spawn reply cannot consume the replacement program's early output");
		check(!wire.killed.wait(.02),"stale spawn cleanup must not kill the replacement PID");
		program.close(); client.close();
		Sys.println("session LSP queues: bounded startup input, cancellation, overflow, wake, stale spawn fencing and cleanup passed");
	}
}

private class LspChannel implements Channel {
	final incoming = new sys.thread.Deque<String>();
	public final sent = new sys.thread.Deque<Dynamic>();
	public final killed = new sys.thread.Lock();
	public function new() {}
	public function reply(message:Dynamic):Void incoming.add(haxe.Json.stringify(message));
	public function sendText(text:String):Void {
		var message:Dynamic = haxe.Json.parse(text);
		if (message.op == "hello") reply({id:message.id,ok:true,root:"/work",name:"work",exec:true});
		else if (message.op == "proc.kill") { killed.release(); reply({id:message.id,ok:true}); }
		else sent.add(message);
	}
	public function receive(seconds:Float):Null<String> { var text = incoming.pop(true); if (text == "closed") throw "closed"; return text; }
	public function close():Void incoming.add("closed");
}
