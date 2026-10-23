import rayde.ext.Connection;
import rayde.ext.ExtensionHost;
import rayde.ext.Manager;
import rayde.ext.Manifest;

@:access(rayde.ext.Connection)
class NativeExtensionChecks {
	static function check(value:Bool, message:String):Void { if (!value) throw message; }
	static function until(host:ExtensionHost, want:Dynamic->Bool):Dynamic {
		var end = haxe.Timer.stamp() + 8;
		while (haxe.Timer.stamp() < end) {
			for (m in host.poll()) if (want(m)) return m;
			Sys.sleep(.005);
		}
		throw "Native host reply timed out: " + host.state + " " + host.errors();
	}
	static function wait(done:Void->Bool, tick:Void->Void):Void {
		var end = haxe.Timer.stamp() + 8;
		while (!done() && haxe.Timer.stamp() < end) { tick(); Sys.sleep(.005); }
		check(done(),"Native connection did not reach expected state");
	}
	static function main():Void {
		var root = sys.FileSystem.fullPath("bin/check-native-isolation");
		var library = Sys.systemName() == "Mac" ? "libfault.dylib" : Sys.systemName() == "Windows" ? "fault.dll" : "libfault.so";
		var source = 'native "fixture" { function native_pid():Int32; function native_abort():Void; function native_hang():Void; function native_noise():Void; function native_invalid_ops():Void; function native_large_output():Void; function native_retain(bytes:Int32):Void; }\n'
			+ "registerCommand('pid', () -> trace('pid:' + native_pid()));\n"
			+ "registerCommand('crash', () -> native_abort());\n"
			+ "registerCommand('hang', () -> native_hang());\n"
			+ "registerCommand('noise', () -> native_noise());\n"
			+ "registerCommand('invalid', () -> native_invalid_ops());\n"
			+ "registerCommand('large', () -> native_large_output());\n"
			+ "registerCommand('retain', () -> { native_retain(33554432); trace('retained'); });\n"
			+ "mount(() -> { onCleanup(() -> trace('view released')); return <div>Isolated</div>; }, 'main');";
		var config = {id:"native-test",name:"Native test",main:"main.rays",capabilities:["native:fixture"],natives:{fixture:{path:library,sha256:haxe.crypto.Sha256.make(sys.io.File.getBytes(root + "/" + library)).toHex()}}};
		sys.io.File.saveContent(root + "/main.rays",source);
		var file = root + "/native-test.rayext";
		sys.io.File.saveContent(file,haxe.Json.stringify(config));
		var manifest = Manifest.read(file);
		var embedded = new ExtensionHost(); embedded.start();
		var parent = until(embedded,m -> m.t == "ready").pid;
		check(!embedded.isolated,"Script-only host stopped using embedded execution");
		embedded.stop();
		function start():{host:ExtensionHost,connection:Connection} {
			var connection = new Connection(manifest.mainPath(),() -> source,manifest);
			connection.nativeAllowed = _ -> true;
			connection.start();
			check(connection.host != null && connection.host.isolated,"Native manifest did not select process isolation");
			var host = connection.host;
			until(host,m -> m.t == "registered");
			check(host.processId != null && host.processId != parent,"Native host shares the editor process");
			return {host:host,connection:connection};
		}
		var value = start(), host = value.host;
		host.send({t:"command",id:"pid"});
		var pid = until(host,m -> m.t == "log" && StringTools.startsWith(m.message,"pid:")).message;
		check(pid == "pid:" + host.processId,"Native library executed outside its extension host");
		host.send({t:"run",name:"fiber.rays",source:"registerCommand('fail', () -> { throw 'contained fiber'; }); registerCommand('okay', () -> trace('still alive'));"});
		until(host,m -> m.t == "registered" && m.id == "okay");
		host.send({t:"command",id:"fail"}); until(host,m -> m.t == "error" && m.kind == "view" && (m.message:String).indexOf("contained fiber") >= 0);
		host.send({t:"command",id:"okay"}); until(host,m -> m.t == "log" && m.message == "still alive");
		host.send({t:"run",name:"builtins.rays",source:"import rayde.markdown.render; import rayde.syntax.highlight; trace(render('# Heading')); trace(highlight('var n = 1;', 'haxe')); trace('builtins ready');"});
		until(host,m -> m.t == "log" && m.message == "builtins ready");
		host.send({t:"closed",root:1});
		until(host,m -> m.t == "collected");
		host.send({t:"describe"});
		var description = until(host,m -> m.t == "describe");
		check(description.nodes == 0,"Closing the isolated view retained its node model");
		host.send({t:"command",id:"crash"});
		wait(() -> value.connection.state == "exited",value.connection.tick);
		check(host.exitCode == 1 && host.errors() != "","Native crash was not reported to its connection");
		check(value.connection.queued.length == 0 && Lambda.count(value.connection.registered) == 0,"Crash retained command registrations or queued mutations");
		value = start(); host = value.host;
		host.send({t:"command",id:"retain"}); until(host,m -> m.t == "log" && m.message == "retained");
		host.send({t:"command",id:"hang"});
		Sys.sleep(.1);
		var hungPid = host.processId;
		var began = haxe.Timer.stamp(); value.connection.stop();
		check(haxe.Timer.stamp() - began < .1,"Stopping a hung native extension blocked its caller");
		if (Sys.systemName() != "Windows") {
			function exists():Bool {
				var process = new sys.io.Process("/bin/kill",["-0",Std.string(hungPid)]);
				var code = process.exitCode(); process.close(); return code == 0;
			}
			wait(() -> !exists(),() -> {});
		}
		value = start(); host = value.host;
		host.send({t:"command",id:"noise"});
		wait(() -> value.connection.state == "exited",value.connection.tick);
		check(host.errors() != "","Malformed native stdout was not rejected");
		value = start(); host = value.host;
		host.send({t:"command",id:"invalid"});
		wait(() -> value.connection.state == "exited",value.connection.tick);
		check(host.errors().indexOf("fields") >= 0,"Malformed native operations reached the editor");
		value = start(); host = value.host;
		host.send({t:"command",id:"large"});
		wait(() -> value.connection.state == "exited",value.connection.tick);
		check(host.errors().indexOf("length") >= 0,"Unterminated native stdout exceeded the message limit");
		value = start(); host = value.host;
		check(!host.send({t:"run",source:[for (_ in 0...17 * 1024) StringTools.lpad("","x",1024)].join("")}),"Oversized native host input was accepted");
		host.send({t:"shutdown"});
		wait(() -> host.state == "exited",() -> { host.poll(); });
		check(host.exitCode == 0,"Graceful isolated shutdown failed");
		value.connection.stop();
		var installed = root + "/installed", folder = installed + "/once";
		sys.FileSystem.createDirectory(folder);
		sys.io.File.copy(root + "/" + library,folder + "/" + library);
		var managed:Dynamic = haxe.Json.parse(haxe.Json.stringify(config));
		managed.id = "once"; managed.capabilities = ["native:fixture","workspace.write"];
		managed.activationEvents = ["onCommand:crash"];
		sys.io.File.saveContent(folder + "/once.rayext",haxe.Json.stringify(managed));
		sys.io.File.saveContent(folder + "/main.rays",'import rayde.workspace.writeFile; native "fixture" { function native_abort():Void; } registerCommand("crash", () -> { await writeFile("marker", "once"); native_abort(); });');
		var writes = 0, releases = 0;
		var manager = new Manager(root,{builtins:installed,user:root + "/no-user",defaultEvents:[],restartLimit:3,restartWindow:60});
		manager.discover({readFile:_ -> null,activeFile:() -> null,root:() -> root,openFile:_ -> {},writeFile:(_,_) -> writes++,replay:_ -> null,releaseLanguages:_ -> releases++},[]);
		manager.start();
		check(manager.command("once","crash",null),"Native command activation failed");
		var entry = manager.find("once");
		wait(() -> entry.restarts.length == 1 && entry.connection.registered.exists("crash"),() -> manager.tick());
		var end = haxe.Timer.stamp() + .2;
		while (haxe.Timer.stamp() < end) { manager.tick(); Sys.sleep(.005); }
		check(writes == 1 && releases > 0,"Native restart replayed a mutating command or failed to release registrations");
		manager.dispose();
		Sys.println("Native extensions: separate PIDs, matching native execution, view collection, crash containment, hanging-call stop, protocol validation and graceful exit");
	}
}
