package rayde.lang;

private typedef Document = {language:String, text:String, version:Int, sent:Int, sentText:String};
private typedef Pending = {done:Dynamic->Void, deadline:Float, scope:String};

/** A workspace session, independent of editor views. Failure of a request leaves the process alive. */
class LspClient {
	public final config:Dynamic;
	public final root:String;
	public var state(default, set) = "starting";
	public var capabilities(default, null):Dynamic = {};
	public var onLog:(String, String)->Void = (_, _) -> {};
	public var onDiagnostics:Dynamic->Void = _ -> {};
	public var onReady:Void->Void = () -> {};
	public var onWake:Void->Void = () -> {};
	public var onStateChanged:Void->Void = () -> {};
	final documents = new Map<String, Document>();
	final pending = new Map<Int, Pending>();
	var transport:Null<LspTransport>;
	var nextId = 0;
	var attempts:Array<Float> = [];
	var retryAt = 0.;
	var closingAt = 0.;
	var startedAt = 0.;
	var disposed = false;
	var resumeAfterClose = false;
	var dirty = false;

	function set_state(value:String):String {
		if (state != value) { state = value; if (onStateChanged != null) onStateChanged(); }
		return value;
	}

	public function new(root:String, config:Dynamic) {
		this.root = root;
		this.config = config;
		if (config.lazy == true) state = "idle";
	}

	public function supports(capability:String):Bool {
		var value:Dynamic = Reflect.field(capabilities, capability);
		return state == "ready" && value != null && value != false;
	}

	public function sync(file:String, language:String, text:String):Void {
		if (state == "idle") state = "starting";
		var doc = documents.get(file);
		if (doc == null) { documents.set(file, {language:language, text:text, version:1, sent:0, sentText:""}); dirty = true; }
		else if (doc.text != text) {
			doc.text = text; doc.version++; dirty = true;
			cancelFile(file);
		}
		if (doc == null || doc.sent != doc.version) onWake();
	}

	public function closeDocument(file:String):Void {
		var doc = documents.get(file);
		if (doc == null) return;
		if (doc.sent > 0 && state == "ready") notify("textDocument/didClose", {textDocument:{uri:LspProtocol.uri(file)}});
		documents.remove(file);
		cancelFile(file);
	}

	public function files():Array<String> return [for (file in documents.keys()) file];
	public function abort():Void { disposed = true; documents.clear(); forceClose(); }
	public function version(file:String):Int return documents.exists(file) ? documents.get(file).version : -1;

	public function saved(file:String):Void {
		if (state != "ready" || !documents.exists(file)) return;
		flush();
		var sync:Dynamic = capabilities.textDocumentSync;
		if (sync != null && !Std.isOfType(sync, Int) && sync.save != null && sync.save != false) {
			var params:Dynamic = {textDocument:{uri:LspProtocol.uri(file)}};
			if (sync.save != true && sync.save.includeText == true) params.text = documents.get(file).text;
			notify("textDocument/didSave", params);
		}
	}

	/** Replacing a scoped request cancels it locally and asks the server to cancel its work. */
	public function request(method:String, params:Dynamic, done:Dynamic->Void, scope = "", timeout = 8.):Int {
		if (scope != "") cancelScope(scope);
		if (state != "ready" && method != "initialize" && method != "shutdown") { done(null); return -1; }
		if (state == "ready") flush();
		var id = ++nextId;
		pending.set(id, {done:done, deadline:haxe.Timer.stamp() + timeout, scope:scope});
		if (transport == null || !transport.send({jsonrpc:"2.0", id:id, method:method, params:params})) fail("Language server input queue is unavailable");
		onWake();
		return id;
	}

	public function cancelScope(scope:String):Void {
		for (id in [for (id => p in pending) if (p.scope == scope) id]) cancel(id);
	}

	public function cancelFile(file:String):Void {
		for (id in [for (id => p in pending) if (StringTools.startsWith(p.scope, file + "#")) id]) cancel(id);
	}

	function cancel(id:Int):Void {
		pending.remove(id);
		if (state == "ready") notify("$/cancelRequest", {id:id});
	}

	function notify(method:String, params:Dynamic):Void {
		if (transport != null && !transport.send({jsonrpc:"2.0", method:method, params:params})) fail("Language server input queue is unavailable");
	}

	function flush():Void {
		if (!dirty) return;
		dirty = false;
		var sync:Dynamic = capabilities.textDocumentSync;
		var kind:Int = sync == null ? 0 : Std.isOfType(sync, Int) ? sync : sync.change == null ? 0 : sync.change;
		for (file => doc in documents) {
			if (doc.sent == doc.version) continue;
			if (doc.sent == 0) notify("textDocument/didOpen", {textDocument:{uri:LspProtocol.uri(file), languageId:doc.language, version:doc.version, text:doc.text}});
			else if (kind != 0) {
				var change:Dynamic = {text:doc.text};
				if (kind == 2) change.range = {start:{line:0, character:0}, end:LspProtocol.position(doc.sentText, doc.sentText.length)};
				notify("textDocument/didChange", {textDocument:{uri:LspProtocol.uri(file), version:doc.version}, contentChanges:[change]});
			}
			if (state != "ready") return;
			doc.sent = doc.version; doc.sentText = doc.text;
		}
	}

	function start():Void {
		var now = haxe.Timer.stamp();
		attempts = [for (at in attempts) if (now - at < 60) at];
		if (attempts.length >= 3) { state = "failed"; onLog("error", "Language server restart limit reached (three starts per minute)"); return; }
		attempts.push(now); startedAt = now; state = "starting";
		try transport = new LspTransport(config) catch (e:Dynamic) fail(Std.string(e));
	}

	function initialize():Void {
		request("initialize", {
			processId:null, rootUri:LspProtocol.uri(root), rootPath:root,
			clientInfo:{name:"RayDE", version:"0.1.0"},
			workspaceFolders:[{uri:LspProtocol.uri(root), name:haxe.io.Path.withoutDirectory(root)}],
			capabilities:{general:{positionEncodings:["utf-16"]},
				workspace:{configuration:true}, textDocument:{
					synchronization:{didSave:true}, publishDiagnostics:{versionSupport:true},
					completion:{completionItem:{snippetSupport:false}}, hover:{contentFormat:["markdown", "plaintext"]},
					documentSymbol:{hierarchicalDocumentSymbolSupport:true}, signatureHelp:{signatureInformation:{parameterInformation:{labelOffsetSupport:true}}}}},
			initializationOptions:config.initializationOptions
		}, result -> {
			if (result == null || result.capabilities == null) { fail("Language server initialization failed"); return; }
			capabilities = result.capabilities;
			if (capabilities.positionEncoding != null && capabilities.positionEncoding != "utf-16") { fail("Language server must support UTF-16 positions"); return; }
			state = "ready";
			notify("initialized", {});
			flush();
			onLog("info", "Language server ready");
			onReady();
		}, "", 20);
	}

	public function tick():Void {
		var now = haxe.Timer.stamp();
		if (state == "closing") {
			if (now >= closingAt) forceClose();
			else read();
			return;
		}
		if (disposed || state == "failed" || state == "idle" || state == "stopped") return;
		if (transport == null && now >= retryAt) start();
		read();
		if (state == "starting" && now - startedAt > 22) { fail("Language server initialization timed out"); return; }
		for (id in [for (id => p in pending) if (p.deadline < now) id]) {
			var p = pending.get(id); cancel(id); p.done(null);
			onLog("warning", "Language server request timed out");
		}
		if (state == "ready") flush();
	}

	public function pollDelay():Float {
		if (state != "ready") return .025;
		for (_ in pending) return .016;
		if (dirty) return .016;
		return .2;
	}

	function read():Void {
		if (transport == null) return;
		var events = transport.poll();
		if (events == null) return;
		for (event in events) {
			if (transport == null) break;
			switch (event.t:String) {
				case "connected": initialize();
				case "stderr": onLog("info", event.message);
				case "error": if (state == "closing") forceClose(); else fail(event.message);
				case "message": try message(event.body) catch (e:Dynamic) fail('Invalid language server message: $e');
			}
		}
	}

	function message(message:Dynamic):Void {
		if (message.method != null) {
			var params:Dynamic = message.params;
			if (Reflect.hasField(message, "id")) {
				var reply:Dynamic = {jsonrpc:"2.0", id:message.id};
				switch (message.method:String) {
					case "workspace/configuration": reply.result = [for (item in (params.items:Array<Dynamic>)) configuration(item.section)];
					case "window/workDoneProgress/create": reply.result = null;
					case "workspace/workspaceFolders": reply.result = [{uri:LspProtocol.uri(root), name:haxe.io.Path.withoutDirectory(root)}];
					case _: reply.error = {code:-32601, message:"Client method not supported"};
				}
				if (!transport.send(reply)) fail("Language server input queue is unavailable");
			} else switch (message.method:String) {
				case "textDocument/publishDiagnostics":
					var file = LspProtocol.path(params.uri), doc = file == null ? null : documents.get(file);
					if (doc != null && doc.sent == doc.version && (params.version == null || params.version == doc.version)) onDiagnostics(params);
				case "window/logMessage" | "window/showMessage": onLog(params.type == 1 ? "error" : params.type == 2 ? "warning" : "info", params.message);
				case _:
			}
		} else if (Reflect.hasField(message, "id")) {
			var id = Std.parseInt(Std.string(message.id)), p = id == null ? null : pending.get(id);
			if (p == null) return;
			pending.remove(id);
			if (message.error != null) onLog("warning", 'Language server request failed: ${message.error.message}');
			p.done(message.error == null ? message.result : null);
		}
	}

	function configuration(section:Null<String>):Dynamic {
		var value:Dynamic = config.settings == null ? {} : config.settings;
		if (section != null && section != "") for (part in section.split(".")) value = value == null ? null : Reflect.field(value, part);
		return value;
	}

	function fail(error:String):Void {
		if (state == "closing") { forceClose(); return; }
		if (disposed) return;
		if (transport != null) transport.close();
		transport = null; capabilities = {}; state = "restarting";
		for (doc in documents) { doc.sent = 0; doc.sentText = ""; }
		dirty = true;
		var callbacks = [for (p in pending) p]; pending.clear();
		retryAt = haxe.Timer.stamp() + Math.min(4, Math.pow(2, attempts.length - 1));
		onLog("error", error);
		for (p in callbacks) p.done(null);
	}

	/** Explicit controls retain document data; a new process replays the current unsaved text. */
	public function startSession():Void {
		if (disposed || state == "ready" || state == "starting" || state == "restarting") return;
		if (state == "closing") { resumeAfterClose = true; return; }
		attempts = []; retryAt = 0; capabilities = {};
		for (doc in documents) { doc.sent = 0; doc.sentText = ""; }
		dirty = true;
		state = "starting"; onWake();
	}

	public function restartSession():Void {
		if (disposed) return;
		stopSession();
		startSession();
	}

	/** Graceful shutdown is polled; it never waits for the server on the caller's thread. */
	public function stopSession():Void {
		resumeAfterClose = false;
		if (state == "closing") return;
		pending.clear();
		if (state == "ready" && transport != null) {
			state = "closing"; closingAt = haxe.Timer.stamp() + 1;
			request("shutdown", null, _ -> {
				if (transport != null) transport.send({jsonrpc:"2.0", method:"exit"});
				closingAt = haxe.Timer.stamp() + .1;
			}, "", 1);
		} else forceClose();
		onWake();
	}

	public function dispose():Void {
		if (disposed) return;
		disposed = true;
		documents.clear();
		stopSession();
	}

	function forceClose():Void {
		if (transport != null) transport.close();
		transport = null; capabilities = {}; state = "stopped"; pending.clear();
		if (resumeAfterClose && !disposed) { resumeAfterClose = false; startSession(); }
	}
}
