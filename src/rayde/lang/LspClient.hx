package rayde.lang;

private typedef Document = {language:String, text:String, version:Int, sent:Int, sentText:String, analyzed:Int};
private typedef Progress = {label:String, order:Int};
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
	public var onDocumentActivity:String->Void = _ -> {};
	public var onProgress:Void->Void = () -> {};
	final documents = new Map<String, Document>();
	final pending = new Map<Int, Pending>();
	final progress = new Map<String, Progress>();
	final workFields = new Map<String, {title:String, message:String, percentage:Null<Float>}>();
	var progressOrder = 0;
	var progressChanged = false;
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
		var changed = doc == null || doc.text != text, waiting = doc != null && doc.analyzed < doc.version;
		if (doc == null) { documents.set(file, {language:language, text:text, version:1, sent:0, sentText:"", analyzed:0}); dirty = true; }
		else if (doc.text != text) {
			doc.text = text; doc.version++; dirty = true;
			setProgress("document:" + file, null);
			cancelFile(file);
		}
		if (config.diagnosticProgress == true && changed && !waiting) onDocumentActivity(file);
		publishProgress();
		if (doc == null || doc.sent != doc.version) onWake();
	}

	public function closeDocument(file:String):Void {
		var doc = documents.get(file);
		if (doc == null) return;
		if (doc.sent > 0 && state == "ready") notify("textDocument/didClose", {textDocument:{uri:LspProtocol.uri(file)}});
		documents.remove(file);
		setProgress("document:" + file, null);
		if (!documents.keys().hasNext()) clearProgress();
		if (config.diagnosticProgress == true && doc.analyzed < doc.version) onDocumentActivity(file);
		cancelFile(file);
		publishProgress();
		onWake();
	}

	/** Opt-in servers publish diagnostics after every document analysis, including an empty result. **/
	public function indexing(file:String):Bool {
		if (state != "ready" || config.diagnosticProgress != true) return false;
		var doc = documents.get(file);
		return doc != null && doc.analyzed < doc.version;
	}

	/** Only live progress is retained; the most recently reported task is shown. */
	public function activity():Null<String> {
		var latest:Null<Progress> = null;
		for (value in progress) if (latest == null || value.order > latest.order) latest = value;
		return latest == null ? null : latest.label;
	}

	function setProgress(key:String, label:Null<String>):Void {
		var previous = activity();
		if (label == null) progress.remove(key);
		else if (!progress.exists(key) || progress.get(key).label != label)
			progress.set(key, {label:label, order:++progressOrder});
		if (previous != activity()) progressChanged = true;
	}

	function clearProgress():Void {
		if (progress.keys().hasNext()) { progress.clear(); progressChanged = true; }
		workFields.clear();
	}

	function publishProgress():Void {
		if (progressChanged) { progressChanged = false; onProgress(); }
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
				window:{workDoneProgress:true}, workspace:{configuration:true,workspaceEdit:{documentChanges:true}}, experimental:{rayzorIndexProgress:true}, textDocument:{
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

	/** A ready process sleeps without documents; explicit requests and lifecycle work still need replies. */
	public function needsPolling():Bool {
		if (state == "closing") return true;
		if (disposed || state == "failed" || state == "idle" || state == "stopped") return false;
		return state != "ready" || documents.keys().hasNext() || pending.keys().hasNext();
	}

	public function tick():Void {
		publishProgress();
		if (!needsPolling()) return;
		var now = haxe.Timer.stamp();
		if (state == "closing") {
			if (now >= closingAt) forceClose();
			else read();
			return;
		}
		if (transport == null && now >= retryAt) start();
		read();
		if (state == "starting" && now - startedAt > 22) { fail("Language server initialization timed out"); return; }
		for (id in [for (id => p in pending) if (p.deadline <= now) id]) {
			var p = pending.get(id); cancel(id); p.done(null);
			onLog("warning", "Language server request timed out");
		}
		if (state == "ready") flush();
		publishProgress();
	}

	public function hasEvents():Bool return transport != null && transport.pending();

	/** Native input wakes the window; timers cover only deadlines and adapters without wake support. */
	public function pollDelay():Null<Float> {
		if (transport == null && state == "restarting") return Math.max(0, retryAt - haxe.Timer.stamp());
		if (transport == null || !transport.canWake()) {
			if (state != "ready") return .025;
			for (_ in pending) return .016;
			return dirty ? .016 : .2;
		}
		if (hasEvents() || state == "ready" && dirty) return 0.;
		var now = haxe.Timer.stamp(), delay:Null<Float> = switch state {
			case "closing": Math.max(0, closingAt - now);
			case "starting": Math.max(0, startedAt + 22 - now);
			case "restarting": Math.max(0, retryAt - now);
			case _: null;
		};
		for (request in pending) {
			var left = Math.max(0, request.deadline - now);
			if (delay == null || left < delay) delay = left;
		}
		return delay;
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
				case "$/progress": workProgress(params);
				case "rayzor/analysisStatus" | "rayzor/indexProgress": rayzorProgress(message.method, params);
				case "textDocument/publishDiagnostics":
					var file = LspProtocol.path(params.uri), doc = file == null ? null : documents.get(file);
					if (doc != null && doc.sent == doc.version && (params.version == null || params.version == doc.version)) {
						var waiting = indexing(file);
						if (capabilities.experimental == null || capabilities.experimental.analysisStatusProvider != true) doc.analyzed = doc.version;
						if (waiting != indexing(file)) onDocumentActivity(file);
						onDiagnostics(params);
					}
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

	function workProgress(params:Dynamic):Void {
		if (state != "ready" || params == null || params.token == null || params.value == null) return;
		var key = "work:" + haxe.Json.stringify(params.token), value:Dynamic = params.value;
		if (value.kind == "end") { setProgress(key, null); workFields.remove(key); return; }
		if (value.kind != "begin" && value.kind != "report") return;
		var previous = progress.get(key);
		if (value.kind == "report" && previous == null) return;
		// Preserve omitted fields in reports, without retaining prior messages.
		if (value.kind == "begin") {
			if (!Std.isOfType(value.title, String)) return;
			workFields.set(key, {title:value.title, message:"", percentage:null});
		}
		var fields = workFields.get(key);
		if (fields == null) return;
		if (Std.isOfType(value.message, String)) fields.message = value.message;
		if (Std.isOfType(value.percentage, Int) || Std.isOfType(value.percentage, Float)) fields.percentage = Math.max(0, Math.min(100, value.percentage));
		setProgress(key, fields.title + (fields.message == "" ? "" : ": " + fields.message) + (fields.percentage == null ? "" : ' (${Math.floor(fields.percentage)}%)'));
	}

	function rayzorProgress(method:String, params:Dynamic):Void {
		if (state != "ready" || params == null) return;
		var workspace = params.scope == "workspace";
		var file = Std.isOfType(params.uri, String) ? LspProtocol.path(params.uri) : null;
		var doc = file == null ? null : documents.get(file);
		if (!workspace && (doc == null || doc.sent != doc.version || (params.version != null && params.version != doc.version))) return;
		var key = workspace ? "rayzor:workspace" : "document:" + file;
		if (params.state == "ready" || params.state == "finished") {
			setProgress(key, null);
			if (!workspace) { var waiting = indexing(file); doc.analyzed = doc.version; if (waiting) onDocumentActivity(file); }
			return;
		}
		var subject:String = Std.isOfType(params.subject, String) && params.subject != "" ? params.subject : file == null ? "workspace" : haxe.io.Path.withoutDirectory(file);
		var phase = params.phase == "scanning" ? "scanning" : method == "rayzor/analysisStatus" ? "checking" : "indexing";
		var count = Std.isOfType(params.completed, Int) && params.completed >= 0 ? ' (${params.completed}' + (Std.isOfType(params.total, Int) && params.total > 0 ? '/${params.total}' : "") + ")" : "";
		setProgress(key, phase + " " + subject + count);
	}

	function configuration(section:Null<String>):Dynamic {
		var value:Dynamic = config.settings == null ? {} : config.settings;
		if (section != null && section != "") for (part in section.split(".")) value = value == null ? null : Reflect.field(value, part);
		return value;
	}

	function fail(error:String):Void {
		if (state == "closing") { forceClose(); return; }
		if (disposed) return;
		clearProgress(); publishProgress();
		if (transport != null) transport.close();
		transport = null; capabilities = {}; state = "restarting";
		for (doc in documents) { doc.sent = 0; doc.sentText = ""; doc.analyzed = 0; }
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
		for (doc in documents) { doc.sent = 0; doc.sentText = ""; doc.analyzed = 0; }
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
		clearProgress(); publishProgress();
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
		clearProgress(); publishProgress();
		if (transport != null) transport.close();
		transport = null; capabilities = {}; state = "stopped"; pending.clear();
		if (resumeAfterClose && !disposed) { resumeAfterClose = false; startSession(); }
	}
}
