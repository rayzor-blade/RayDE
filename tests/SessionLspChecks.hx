import haxe.io.Bytes;
import rayde.lang.LanguageServers;
import rayde.lang.LspClient;
import rayde.lang.LspFrames;
import rayde.lang.LspProtocol;
import rayde.workspace.Procs;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.SessionLauncher;

class SessionLspChecks {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;
	static function until(servers:LanguageServers, ready:Void->Bool, seconds = 10.):Void {
		var end = haxe.Timer.stamp()+seconds;
		while (!ready() && haxe.Timer.stamp() < end) { servers.tick(); Sys.sleep(.002); }
		check(ready(),"Remote LSP did not settle");
	}
	static function query(servers:LanguageServers, client:LspClient, method:String, ?params:Dynamic):Dynamic {
		var ready = false, result:Dynamic = null;
		client.request(method,params ?? {},value -> { result = value; ready = true; });
		until(servers,() -> ready); return result;
	}
	static function frames():Void {
		var text = "λ😀漢字", messages:Array<Dynamic> = [];
		var wire = LspFrames.frame({jsonrpc:"2.0",id:1,result:text});
		var framed = new LspFrames((body, _) -> messages.push(body));
		for (at in 0...wire.length) framed.push(wire.sub(at,1),1);
		framed.push(wire,wire.length); framed.finish();
		check(messages.length == 2 && messages[0].result == text,"framing survives split headers and UTF-8 code points");
		for (header in ["Content-Length: 99999999\r\n\r\n", "Content-Length: 1x\r\n\r\n", "Content-Length: 2\r\nContent-Length: 3\r\n\r\n", "Unknown: 2\r\n\r\n"]) {
			var rejected = false;
			try { var bytes = Bytes.ofString(header); new LspFrames((_,_) -> {}).push(bytes,bytes.length); } catch (_:Dynamic) rejected = true;
			check(rejected,"invalid frame lengths must fail before body allocation");
		}
		var incomplete = new LspFrames((_,_) -> {}); incomplete.push(wire,wire.length-1);
		var rejected = false; try incomplete.finish() catch (_:Dynamic) rejected = true;
		check(rejected,"an incomplete frame must not be silently accepted");
	}
	static function main():Void {
		frames();
		var root = Sys.getCwd()+"bin/session-lsp-"+Std.random(0x3fffffff), project = root+"/project";
		sys.FileSystem.createDirectory(project);
		sys.io.File.copy("tests/lsp_server_fixture.py",root+"/fixture.py");
		var port = 20000+Std.random(20000), server = new sys.io.Process("native/session/target/debug/rayde-session",["--root",root,"--port",Std.string(port),"--token","lsp-check","--exec"]);
		var session:SessionClient = null, previous = Procs.current, servers:LanguageServers = null;
		try {
			for (_ in 0...100) {
				try { session = SessionClient.connect("127.0.0.1",port,"lsp-check"); break; } catch (_:Dynamic) Sys.sleep(.02);
			}
			check(session != null,"the session starts");
			var owner = sys.thread.Thread.current(), wrongThread = false, wakes = 0;
			session.subscribe(_ -> if (sys.thread.Thread.current() != owner) wrongThread = true);
			session.onWake = () -> wakes++;
			Procs.current = new SessionLauncher(session);
			check(rayde.lang.RayzorBinary.find() == "rayzor","remote Rayzor resolves on its session host PATH");
			var file = project+"/Main.hx", events = project+"/events", logs:Array<String> = [], diagnostics:Array<Dynamic> = [];
			servers = new LanguageServers(project);
			servers.onDiagnostics = diagnostics.push;
			servers.register("test",{id:"remote",lazy:true,diagnosticProgress:true,languages:["haxe"],fileExtensions:[".hx"],transport:{kind:"stdio",command:"python3",args:[root+"/fixture.py",events],env:{LSP_SYNC_KIND:"2",RAYDE_LSP_FIXTURE_MARKER:"remote-only"}}},(_,message) -> logs.push(message));
			var client = servers.client(file);
			check(client.state == "idle" && !sys.FileSystem.exists(events),"no LSP process starts on an empty welcome page");
			servers.sync(file,"class Main {} λ😀");
			until(servers,() -> client.state == "ready");
			var state = query(servers,client,"test/state");
			check(state.cwd == sys.FileSystem.fullPath(project) && state.marker == "remote-only","cwd and environment belong to the remote process");
			check(Reflect.field(state.documents,LspProtocol.uri(file)).text == "class Main {} λ😀","unsaved UTF-16 text reaches remote didOpen");
			var pid:Int = state.pid;
			servers.sync(file,"class Main { var x = '😀'; }");
			state = query(servers,client,"test/state");
			check(Reflect.field(state.documents,LspProtocol.uri(file)).version == 2,"incremental synchronization carries versions and UTF-16 ranges");
			var order:Array<Int> = [], ids:Array<Int> = [];
			for (_ in 0...32) ids.push(client.request("test/deferred",{},value -> order.push(value)));
			query(servers,client,"test/reverse"); ids.reverse();
			check(order.join(",") == ids.join(","),"concurrent responses settle by ID, in server order");
			var cancelled = false;
			client.request("test/deferred",{},_ -> cancelled = true,file+"#hover"); client.cancelScope(file+"#hover");
			query(servers,client,"test/reverse"); check(!cancelled,"late cancelled responses stay cancelled");
			check(query(servers,client,"test/error") == null && query(servers,client,"test/state").pid == pid,"one request error does not drop the server");
			client.request("test/state",{},_ -> { throw "fixture view callback failed"; });
			query(servers,client,"test/state");
			check(client.state == "ready" && logs.join("\n").indexOf("result callback failed") >= 0,"a view callback failure does not restart its healthy server");
			var large = StringTools.lpad("","λ😀",300000);
			check(query(servers,client,"test/echo",{text:large}).text == large,"large UTF-8 messages cross session write chunks and output frames");
			query(servers,client,"test/stderr");
			until(servers,() -> logs.join("\n").indexOf("\x1b[31mλ😀\x1b[0m") >= 0);
			query(servers,client,"test/diagnostics",{uri:LspProtocol.uri(file)});
			check(diagnostics.length == 1 && diagnostics[0].version == 2,"current remote diagnostics reach the client");
			check(client.pollDelay() == null && wakes > 0,"ready remote LSP sleeps until a stream event wakes it");
			servers.control("remote","stop"); until(servers,() -> client.state == "stopped");
			servers.control("remote","start"); until(servers,() -> client.state == "ready");
			check(query(servers,client,"test/state").pid != pid,"restart launches a fresh remote process and restores documents");
			servers.retain([]); query(servers,client,"test/state");
			check(!servers.busy(),"closing all documents pauses LSP polling");
			check(!wrongThread,"process workers must never drain UI event subscribers");
			servers.dispose();
			var rayzor = Sys.getEnv("RAYDE_RAYZOR_LSP");
			if (rayzor != null && rayzor != "") realServer(session,project,rayzor);
			session.close(); Procs.current = previous;
		} catch (error:Dynamic) {
			if (servers != null) servers.dispose(); if (session != null) session.close(); Procs.current = previous;
			server.kill(); server.close(); throw error;
		}
		server.kill(); server.close();
		Sys.println("remote LSP: framing, lazy start, cwd/env, Unicode, concurrent replies, cancellation, errors, large messages, ANSI logs, diagnostics, sleep, restart and cleanup passed");
	}
	static function realServer(session:SessionClient, root:String, executable:String):Void {
		var source = "class Main {\n static function add(a:Int,b:Int):Int { return a+b; }\n static function main() { var total = add(1,2); trace(total); }\n}\n";
		var files = new rayde.workspace.session.SessionWorkspace(session), file = root+"/Main.hx";
		files.saveContent(file,source); files.saveContent(root+"/build.hxml","-cp .\n-main Main\n--interp\n");
		var servers = new LanguageServers(root), logs:Array<String> = [], env:Dynamic = {};
		var stdlib = Sys.getEnv("RAYZOR_STD_PATH"); if (stdlib != null) env.RAYZOR_STD_PATH = stdlib;
		servers.register("real",{id:"rayzor",languages:["haxe"],fileExtensions:[".hx"],transport:{kind:"stdio",command:executable,args:["lsp"],env:env}},(_,message) -> logs.push(message));
		var client = servers.client(file);
		try {
			servers.sync(file,source); until(servers,() -> client.state == "ready",30);
			var completed = 0, semantic = 0;
			for (_ in 0...16) client.request("textDocument/hover",{textDocument:{uri:LspProtocol.uri(file)},position:LspProtocol.position(source,source.indexOf("add(1")+1)},result -> {
				completed++; if (result != null && haxe.Json.stringify(result).indexOf("Int") >= 0) semantic++;
			},"",45);
			until(servers,() -> completed == 16,50);
			check(semantic == 16,"remote Rayzor returns real semantic hover results: "+logs.join("\n"));
			check(query(servers,client,"not/a/method") == null && client.state == "ready","unsupported methods leave remote Rayzor connected");
			servers.control("rayzor","stop"); until(servers,() -> client.state == "stopped");
		} catch (error:Dynamic) { servers.dispose(); throw error; }
		servers.dispose(); Sys.println("session-hosted Rayzor: 16 concurrent semantic hovers and graceful shutdown passed");
		files.saveContent(root+"/run.hxml","-cp .\n-main Main\n-hl ignored.hl\n");
		var compiler = new rayde.lang.CompilerServer(), runner = new rayde.run.Runner(rayde.lang.Display.ofHxml(compiler,root+"/run.hxml"));
		try {
			runner.start();
			var end = haxe.Timer.stamp()+20;
			while (runner.active() && haxe.Timer.stamp()<end) { runner.tick(); Sys.sleep(.005); }
			check(runner.state == "finished" && runner.exitCode == 0 && runner.console.indexOf("3") >= 0,"remote Haxe Run compiles and executes without a local compiler socket: "+runner.console);
			check(!compiler.running(),"remote Run must leave the editor's compiler server asleep");
		} catch (error:Dynamic) { runner.stop(); throw error; }
		runner.stop(); Sys.println("session-hosted Haxe: Run builds and executes without localhost port probes");
	}
}
