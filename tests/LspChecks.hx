import rayde.lang.LanguageServers;
import rayde.lang.LspClient;
import rayde.lang.LspProtocol;

class LspChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	static function until(servers:LanguageServers, condition:Void->Bool, seconds = 8.):Void {
		var end = haxe.Timer.stamp() + seconds;
		while (!condition() && haxe.Timer.stamp() < end) { servers.tick(); Sys.sleep(.005); }
		check(condition(), "LSP condition timed out");
	}
	static function query(servers:LanguageServers, client:LspClient, method:String, ?params:Dynamic):Dynamic {
		var done = false, result:Dynamic = null;
		client.request(method, params == null ? {} : params, value -> { result = value; done = true; });
		until(servers, () -> done);
		return result;
	}
	public static function run():Void {
		var root = Sys.getCwd(), file = root + "bin/lsp-λ+ file.hx", events = root + "bin/lsp-fixture.events";
		if (sys.FileSystem.exists(events)) sys.FileSystem.deleteFile(events);
		check(LspProtocol.path(LspProtocol.uri(file)) == file, "LSP file URI round trip");
		var parts = LspProtocol.hoverParts([{kind:"plaintext", value:"*literal*"}, {language:"haxe", value:"class A { var s = '```'; }"}, "**markdown**"]);
		check(parts.length == 3 && !parts[0].markdown && parts[0].text == "*literal*", "Hover keeps plaintext literal in mixed content");
		check(parts[1].markdown && StringTools.startsWith(parts[1].text, "````haxe\n") && parts[2].markdown, "Legacy MarkedString fences escape code delimiters");
		var text = "λ😀\r\nabc";
		check(LspProtocol.position(text, text.indexOf("abc")).line == 1, "LSP multiline positions");
		check(LspProtocol.position(text, text.indexOf("\r")).character == 3, "LSP positions count UTF-16 units");
		check(LspProtocol.offset(text, {line:0, character:100}) == 3, "LSP offsets clamp to the line");
		var payload:Dynamic = {uri:LspProtocol.uri(file),diagnostics:[{severity:1,message:"Error",range:{start:{line:0,character:0},end:{line:0,character:1}}}]};
		var same = LspProtocol.diagnostics(payload), identical = LspProtocol.diagnostics(haxe.Json.parse(haxe.Json.stringify(payload)));
		check(LspProtocol.sameDiagnostics(same, identical), "Identical republished diagnostics compare by content");
		identical[0].range.end.character++;
		check(!LspProtocol.sameDiagnostics(same, identical), "Changed diagnostic ranges are preserved");
		identical = LspProtocol.diagnostics(payload); identical[0].message = "Other";
		check(!LspProtocol.sameDiagnostics(same, identical), "Changed diagnostic messages are preserved");
		var servers = new LanguageServers(root), logs:Array<String> = [];
		var diagnostics:Array<Dynamic> = [];
		servers.onDiagnostics = value -> diagnostics.push(value);
		var definition:Dynamic = {id:"fixture", diagnosticProgress:true, languages:["haxe"], fileExtensions:[".hx"], transport:{kind:"stdio", command:"python3", args:[root + "tests/lsp_server_fixture.py", events]}};
		servers.register("owner", definition, (kind, text) -> logs.push(kind + ":" + text));
		var client = servers.client(file);
		servers.sync(file, "class A {} λ😀");
		until(servers, () -> client.state == "ready");
		var first = query(servers, client, "test/state");
		check(Reflect.field(first.documents, LspProtocol.uri(file)).text == "class A {} λ😀", "LSP sends initial unsaved contents");
		var pid:Int = first.pid;
		check(servers.status(file).indexing, "An opened document is indexing until its diagnostics arrive");
		query(servers, client, "test/diagnostics", {uri:LspProtocol.uri(file), staleOnly:true});
		check(servers.status(file).indexing && diagnostics.length == 0, "Stale diagnostics do not finish active-file analysis");
		query(servers, client, "test/diagnostics", {uri:LspProtocol.uri(file)});
		check(!servers.status(file).indexing && diagnostics.length == 1, "Empty current diagnostics finish analysis");
		diagnostics.resize(0);
		var activity = 0; servers.onDocumentActivity = _ -> activity++;
		servers.sync(file, "class A {} λ😀");
		check(activity == 0 && !servers.status(file).indexing, "Unchanged synchronization does not trigger activity updates");
		servers.sync(file, "second"); servers.sync(file, "third");
		var current = query(servers, client, "test/state");
		check(Reflect.field(current.documents, LspProtocol.uri(file)).text == "third", "LSP coalesces document edits");
		check(Reflect.field(current.documents, LspProtocol.uri(file)).version == 3, "LSP document versions increase");
		check(servers.status(file).indexing && activity == 1, "Coalesced edits start document activity once");
		query(servers, client, "test/diagnostics", {uri:LspProtocol.uri(file)});
		check(!servers.status(file).indexing && activity == 2, "Analysis completion emits one activity update");
		diagnostics.resize(0);
		var laterFile = root + "bin/lsp-later-open.hx";
		servers.sync(laterFile, "class Later {}");
		current = query(servers, client, "test/state");
		check(Reflect.field(current.documents, LspProtocol.uri(laterFile)).text == "class Later {}", "A document opened after initialization is flushed");
		check(servers.status(laterFile).indexing && !servers.status(file).indexing, "Indexing status is scoped to the requested file");
		servers.sync(laterFile, "class Later {}");
		for (_ in 0...20) servers.tick();
		current = query(servers, client, "test/state");
		check(Reflect.field(current.documents, LspProtocol.uri(laterFile)).version == 1, "Unchanged documents stay synchronized across idle polls");
		client.closeDocument(laterFile);
		check(!servers.status(laterFile).indexing, "Closing a document clears its activity");
		query(servers, client, "test/diagnostics");
		check(diagnostics.length == 1 && diagnostics[0].version == 3, "LSP rejects stale versioned diagnostics");
		client.saved(file);
		var order:Array<Int> = [];
		var a = client.request("test/deferred", {}, r -> order.push(r));
		var b = client.request("test/deferred", {}, r -> order.push(r));
		query(servers, client, "test/reverse");
		check(order.join(",") == b + "," + a, "LSP matches concurrent, out-of-order responses by id");
		var late = false;
		var cancelled = client.request("test/deferred", {}, _ -> late = true, file + "#hover");
		client.cancelScope(file + "#hover");
		query(servers, client, "test/reverse");
		check(!late, "LSP ignores cancelled late responses");
		var timedOut = false;
		client.request("test/deferred", {}, r -> { check(r == null, "Timed out result"); timedOut = true; }, "timeout", .05);
		until(servers, () -> timedOut);
		query(servers, client, "test/reverse");
		current = query(servers, client, "test/state");
		check((current.cancelled:Array<Int>).indexOf(cancelled) >= 0, "LSP sends cancellation to server");
		check(query(servers, client, "test/error") == null, "Request errors resolve without dropping the server");
		check(query(servers, client, "test/state").pid == pid, "Request errors preserve server process");
		var beforeClose = logs.length;
		servers.retain([]);
		check(!servers.busy() && client.state == "ready", "Closing every document pauses polling without stopping the server");
		var closeDeadline = haxe.Timer.stamp() + 5;
		while (sys.io.File.getContent(events).indexOf("close " + LspProtocol.uri(file)) < 0 && haxe.Timer.stamp() < closeDeadline) Sys.sleep(.005);
		check(sys.io.File.getContent(events).indexOf("close " + LspProtocol.uri(file)) >= 0, "Document close reaches the server without polling");
		for (_ in 0...20) { servers.tick(); client.tick(); Sys.sleep(.005); }
		check(logs.length == beforeClose, "Documentless ticks do not drain the server transport");
		current = query(servers, client, "test/state");
		check(current.pid == pid && Reflect.fields(current.documents).length == 0, "Closing every tab closes documents, retaining server process");
		check(logs.join("\n").indexOf("closed " + LspProtocol.uri(file)) >= 0 && !servers.busy(), "Explicit documentless requests resume polling until their replies arrive");
		timedOut = false;
		client.request("test/deferred", {}, _ -> timedOut = true, "welcome-timeout", .05);
		check(servers.busy(), "A request without code tabs still schedules its timeout");
		until(servers, () -> timedOut);
		check(!servers.busy(), "Polling pauses again after a documentless request times out");
		servers.sync(file, "replayed after crash");
		check(servers.busy(), "Opening a code document resumes a paused server");
		client.request("test/crash", {}, _ -> {});
		until(servers, () -> client.state == "restarting");
		until(servers, () -> client.state == "ready");
		current = query(servers, client, "test/state");
		check(current.pid != pid && Reflect.field(current.documents, LspProtocol.uri(file)).text == "replayed after crash", "Server crash restarts and replays current documents");
		servers.control("fixture", "stop");
		until(servers, () -> client.state == "stopped");
		check(servers.client(file) == null && servers.status(file).state == "stopped" && !servers.status(file).indexing && !servers.busy(), "Stop exposes stopped registration without polling or automatic relaunch");
		servers.sync(file, "edited while stopped");
		for (_ in 0...5) servers.tick();
		check(client.state == "stopped", "Document edits do not restart a stopped server");
		servers.control("fixture", "start");
		until(servers, () -> client.state == "ready");
		current = query(servers, client, "test/state");
		check(Reflect.field(current.documents, LspProtocol.uri(file)).text == "edited while stopped", "Start replays edits made while stopped");
		pid = current.pid;
		servers.control("fixture", "restart");
		until(servers, () -> client.state == "ready");
		current = query(servers, client, "test/state");
		check(current.pid != pid && Reflect.field(current.documents, LspProtocol.uri(file)).text == "edited while stopped", "Manual restart replaces the process and replays unsaved text");
		check(servers.status(file).indexing, "Restarted servers reanalyse retained document contents");
		query(servers, client, "test/diagnostics", {unversioned:true});
		check(!servers.status(file).indexing, "Unversioned Rayzor diagnostics also complete analysis");
		servers.release("stranger");
		check(servers.client(file) == client, "An extension cannot unregister another extension's server");
		servers.release("owner");
		until(servers, () -> !servers.busy());
		check(servers.client(file) == null, "Extension disposal removes its registration");
		var recorded = sys.io.File.getContent(events);
		check(recorded.indexOf("save third") >= 0 && recorded.indexOf("shutdown") >= 0 && recorded.indexOf("exit") >= 0, "LSP sends save, shutdown and exit");
		var incremental = new LanguageServers(root);
		incremental.register("incremental", {id:"incremental", languages:["haxe"], fileExtensions:[".hx"], transport:{kind:"stdio", command:"python3",
			args:[root + "tests/lsp_server_fixture.py", events], env:{LSP_SYNC_KIND:"2"}}}, (_, _) -> {});
		var inc = incremental.client(file);
		incremental.sync(file, "λ😀\nold 😀");
		until(incremental, () -> inc.state == "ready");
		check(!incremental.status(file).indexing, "Servers without diagnostic activity opt-in never wait for diagnostics");
		incremental.sync(file, "replaced");
		check(Reflect.field(query(incremental, inc, "test/state").documents, LspProtocol.uri(file)).text == "replaced", "Incremental synchronization uses a UTF-16 full replacement range");
		incremental.release("incremental"); until(incremental, () -> !incremental.busy());
		extensionChecks(root);
		var failed = new LanguageServers(root);
		failed.register("broken", {id:"broken", languages:["haxe"], fileExtensions:[".hx"], transport:{kind:"stdio", command:"rayde-nonexistent-lsp-fixture", args:[]}}, (_, _) -> {});
		var broken = failed.client(file);
		until(failed, () -> broken.state == "failed", 12);
		check(failed.client(file) == null && !failed.busy(), "Repeated startup failure stops retries and restores fallback routing");
		failed.dispose();
		var rayzor = Sys.getEnv("RAYDE_RAYZOR_LSP");
		if (rayzor != null && rayzor != "") realServer(root, rayzor);
		Sys.println("LSP checks passed");
	}

	static function realServer(base:String, command:String):Void {
		var root = base + "bin/lsp-real-rayzor", file = root + "/Main.hx";
		sys.FileSystem.createDirectory(root);
		var source = "class Main {\n    static function add(a:Int, b:Int):Int {\n        return a + b;\n    }\n    static function main() {\n        var total = add(1, 2);\n        trace(total);\n    }\n}\n";
		sys.io.File.saveContent(file, source);
		var servers = new LanguageServers(root), logs:Array<String> = [];
		servers.register("real", {id:"rayzor", diagnosticProgress:true, languages:["haxe"], fileExtensions:[".hx"], transport:{kind:"stdio", command:command, args:["lsp"]}},
			(kind, text) -> logs.push(kind + ":" + text));
		var client = servers.client(file);
		try {
			until(servers, () -> client.state == "ready", 20);
			servers.sync(file, source);
			check(servers.status(file).indexing, "Real Rayzor marks an opened document as analysing");
			var answered = 0, hovers:Array<Dynamic> = [];
			for (_ in 0...32) client.request("textDocument/hover", {textDocument:{uri:LspProtocol.uri(file)}, position:{line:1, character:21}}, result -> {
				hovers.push(result); answered++;
			}, "", 20);
			until(servers, () -> answered == 32, 22);
			for (hover in hovers) check(hover != null && LspProtocol.documentation(hover.contents).indexOf("function add") >= 0, "Real Rayzor answers concurrent hover requests with semantic results");
			check(client.state == "ready", "Real Rayzor remains connected after document request");
			check(!servers.status(file).indexing, "Real Rayzor diagnostics finish active-document analysis");
			servers.retain([]);
			var diagnostics = query(servers, client, "rayde/unsupportedProbe");
			check(client.state == "ready", "Real Rayzor remains connected after document close and unknown request");
			Sys.println("Real Rayzor (" + client.config.command + "): 32 in-flight semantic hover requests, document close and unsupported-request survival passed");
		} catch (error:Dynamic) { servers.dispose(); throw error; }
		servers.release("real"); until(servers, () -> !servers.busy());
	}

	static function extensionChecks(base:String):Void {
		var root = base + "bin/lsp-extension";
		sys.FileSystem.createDirectory(root);
		var command = root + "/server", events = root + "/events";
		var fixture = base + "tests/lsp_server_fixture.py";
		sys.io.File.saveContent(command, "#!/usr/bin/env python3\nimport runpy, sys\nsys.argv = [" + haxe.Json.stringify(fixture) + ", " + haxe.Json.stringify(events) + "]\nrunpy.run_path(sys.argv[0], run_name='__main__')\n");
		Sys.command("chmod", ["+x", command]);
		rayde.settings.Store.save(root, "extension.rayzor", {command:command});
		var manifest = rayde.ext.Manifest.read(base + "extensions/rayzor/rayzor.rayext");
		check(manifest.problems.length == 0, "Rayzor extension manifest");
		var servers = new LanguageServers(root);
		var connection = new rayde.ext.Connection(manifest.mainPath(), () -> sys.io.File.getContent(manifest.mainPath()) + "\nregisterCommand('fail', args -> { throw 'fixture fiber failure'; });", manifest);
		connection.services = {
			root:() -> root, readFile:_ -> null, activeFile:() -> null, openFile:_ -> {}, writeFile:(_, _) -> {}, replay:_ -> null,
			registerLanguage:(owner, definition, log) -> servers.register(owner, definition, log),
			unregisterLanguage:(owner, id) -> servers.unregister(owner, id),
			languageServers:owner -> servers.servers(owner), releaseLanguages:owner -> servers.release(owner)
		};
		var logs:Array<String> = [];
		connection.onEntry = (_, entry) -> logs.push(entry.text);
		connection.start();
		var file = root + "/Main.hx";
		function waitFor(done:Void->Bool):Void {
			var end = haxe.Timer.stamp() + 8;
			while (!done() && haxe.Timer.stamp() < end) { connection.tick(); servers.tick(); Sys.sleep(.005); }
			check(done(), "RayScript language service registration: " + logs.join("\n"));
		}
		try {
			waitFor(() -> servers.client(file) != null);
			check(servers.client(file).state == "idle" && !servers.busy(), "The built-in server waits for a Haxe document");
			servers.sync(file, "class Main {}");
			waitFor(() -> servers.client(file).state == "ready");
			var client = servers.client(file), pid:Int = query(servers, client, "test/state").pid;
			connection.command("describe", {});
			waitFor(() -> logs.indexOf("rayzor: ready") >= 0);
			connection.command("fail", {});
			waitFor(() -> logs.join("\n").indexOf("fixture fiber failure") >= 0);
			check(connection.running() && servers.client(file) == client && query(servers, client, "test/state").pid == pid, "Script fiber failure preserves the LSP session");
			connection.command("rayzor.restart", {});
			waitFor(() -> servers.client(file) != null && servers.client(file) != client);
			servers.sync(file, "class Main {}");
			waitFor(() -> servers.client(file).state == "ready");
			check(query(servers, servers.client(file), "test/state").pid != pid, "The Rayzor restart command explicitly replaces the server");
			var json:Dynamic = haxe.Json.parse(sys.io.File.getContent(manifest.file)); json.capabilities = [];
			var revoked = @:privateAccess new rayde.ext.Manifest(manifest.file, json);
			connection.useManifest(revoked);
			until(servers, () -> !servers.busy());
			check(servers.client(file) == null, "Revoking language registration capability stops the server");
			connection.stop();
			until(servers, () -> !servers.busy());
			check(servers.client(file) == null, "Stopping the extension releases its language server");
		} catch (e:Dynamic) { connection.stop(); servers.dispose(); throw e; }
		sys.io.File.saveContent(root + "/denied.rayext", '{"id":"denied","main":"denied.rays","capabilities":[]}');
		sys.io.File.saveContent(root + "/denied.rays", "import rayde.languages.registerServer; await registerServer({id:'denied'});");
		var deniedManifest = rayde.ext.Manifest.read(root + "/denied.rayext");
		var denied = new rayde.ext.Connection(deniedManifest.mainPath(), () -> sys.io.File.getContent(deniedManifest.mainPath()), deniedManifest);
		denied.services = connection.services;
		var refused = false;
		denied.onEntry = (_, entry) -> { if (entry.text.indexOf("Capability languages.register is not granted") >= 0) refused = true; };
		denied.start();
		var deadline = haxe.Timer.stamp() + 5;
		while (!refused && haxe.Timer.stamp() < deadline) { denied.tick(); Sys.sleep(.005); }
		denied.stop();
		check(refused && !servers.busy(), "Language server launch requires the manifest capability");
	}
	static function main():Void run();
}
