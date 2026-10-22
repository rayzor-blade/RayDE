package rayde.lang;

private typedef Registration = {id:String, name:String, owner:String, languages:Array<String>, extensions:Array<String>, client:LspClient};

/** Extensions own registrations; the workspace owns processes, documents and asynchronous requests. */
class LanguageServers {
	public var onChanged:Void->Void = () -> {};
	public var onStatus:Void->Void = () -> {};
	public var onDocumentActivity:String->Void = _ -> {};
	public var onWake:Void->Void = () -> {};
	public var onDiagnostics:Dynamic->Void = _ -> {};
	final root:String;
	final entries:Array<Registration> = [];
	final closing:Array<LspClient> = [];

	public function new(root:String) this.root = root;

	static function strings(value:Dynamic):Array<String> {
		if (!Std.isOfType(value, Array)) throw "Expected an array of strings";
		return [for (v in (value:Array<Dynamic>)) {
			if (!Std.isOfType(v, String) || v == "") throw "Expected nonempty strings";
			(v:String);
		}];
	}

	public function register(owner:String, definition:Dynamic, log:(String, String)->Void):String {
		if (definition == null || !Std.isOfType(definition.id, String) || !~/^[a-zA-Z0-9_.-]+$/.match(definition.id)) throw "Language server requires an id";
		var id:String = definition.id;
		var languages = strings(definition.languages), extensions = strings(definition.fileExtensions);
		if (languages.length == 0 || extensions.length == 0) throw "Language server requires languages and fileExtensions";
		for (ext in extensions) if (!~/^\.[A-Za-z0-9_+-]+$/.match(ext)) throw "File extensions must start with a dot";
		var transport:Dynamic = definition.transport;
		if (transport == null || transport.kind != "stdio" || !Std.isOfType(transport.command, String) || transport.command == "") throw "Language server requires a stdio transport and command";
		for (entry in entries) if (entry.id == id && entry.owner != owner) throw 'Language server $id is already registered';
		for (entry in entries) if (!(entry.owner == owner && entry.id == id)) for (ext in extensions)
			if (entry.extensions.indexOf(ext.toLowerCase()) >= 0) throw 'A language server already handles $ext';
		var expand = (value:String) -> StringTools.replace(value, "${workspaceFolder}", root);
		var env:Dynamic = {};
		if (transport.env != null) for (key in Reflect.fields(transport.env)) {
			var value:Dynamic = Reflect.field(transport.env, key);
			if (!Std.isOfType(value, String)) throw "Language server environment values must be strings";
			Reflect.setField(env, key, expand(value));
		}
		var command = expand(transport.command);
		if (command == "rayzor") command = RayzorBinary.find() ?? command;
		var config:Dynamic = {command:command, args:[for (arg in strings(transport.args == null ? [] : transport.args)) expand(arg)],
			cwd:root, env:env, lazy:definition.lazy == true, diagnosticProgress:definition.diagnosticProgress == true, initializationOptions:definition.initializationOptions, settings:definition.settings};
		unregister(owner, id);
		var client = new LspClient(root, config);
		client.onLog = (kind, text) -> log(kind, id + ": " + text);
		client.onDiagnostics = onDiagnostics;
		client.onReady = onChanged;
		client.onStateChanged = () -> onStatus();
		client.onDocumentActivity = file -> onDocumentActivity(file);
		client.onWake = onWake;
		entries.push({id:id, name:Std.isOfType(definition.name, String) ? definition.name : id, owner:owner, languages:languages, extensions:[for (ext in extensions) ext.toLowerCase()], client:client});
		onChanged();
		return id;
	}

	public function unregister(owner:String, id:String):Void {
		for (entry in entries.copy()) if (entry.owner == owner && entry.id == id) {
			entries.remove(entry);
			for (file in entry.client.files()) onDiagnostics({uri:LspProtocol.uri(file), diagnostics:[]});
			entry.client.dispose(); closing.push(entry.client);
			onChanged();
		}
	}
	public function release(owner:String):Void {
		for (entry in entries.copy()) if (entry.owner == owner) unregister(owner, entry.id);
	}
	public function servers(owner:String):Array<Dynamic>
		return [for (entry in entries) if (entry.owner == owner) {id:entry.id, state:entry.client.state, languages:entry.languages.copy()}];

	function registration(file:String):Null<Registration> {
		var extension = "." + haxe.io.Path.extension(file).toLowerCase();
		return Lambda.find(entries, e -> e.extensions.indexOf(extension) >= 0);
	}
	public function client(file:String):Null<LspClient> {
		var entry = registration(file);
		return entry == null || ["failed", "stopped", "closing"].indexOf(entry.client.state) >= 0 ? null : entry.client;
	}
	public function language(file:String):Null<String> {
		var entry = registration(file);
		return entry == null ? null : entry.languages[0];
	}
	public function status(file:String):Null<{id:String, owner:String, name:String, state:String, indexing:Bool}> {
		var entry = registration(file);
		if (entry == null && entries.length > 0) entry = entries[0];
		return entry == null ? null : {id:entry.id, owner:entry.owner, name:entry.name, state:entry.client.state, indexing:entry.client.indexing(file)};
	}
	public function control(id:String, action:String):Void {
		var entry = Lambda.find(entries, e -> e.id == id);
		if (entry == null) return;
		switch action {
			case "start": entry.client.startSession();
			case "restart": entry.client.restartSession();
			case "stop": entry.client.stopSession();
			case _: return;
		}
		if (action != "start") for (file in entry.client.files()) onDiagnostics({uri:LspProtocol.uri(file), diagnostics:[]});
		onChanged();
	}
	public function sync(file:String, text:String):Void {
		var entry = registration(file);
		if (entry != null) entry.client.sync(file, entry.languages[0], text);
	}
	public function retain(files:Array<String>):Void {
		for (entry in entries) for (file in entry.client.files()) if (files.indexOf(file) < 0) entry.client.closeDocument(file);
	}
	public function tick():Void {
		for (entry in entries.copy()) {
			if (!entry.client.needsPolling()) continue;
			var before = entry.client.state;
			entry.client.tick();
			if (before != "failed" && entry.client.state == "failed") onChanged();
		}
		for (client in closing.copy()) { client.tick(); if (client.state == "stopped") closing.remove(client); }
	}
	public function busy():Bool return Lambda.exists(entries, e -> e.client.needsPolling()) || closing.length > 0;
	public function pollDelay():Float {
		var delay = closing.length > 0 ? .025 : .2;
		for (entry in entries) if (entry.client.needsPolling()) delay = Math.min(delay, entry.client.pollDelay());
		return delay;
	}
	public function dispose():Void {
		for (entry in entries) entry.client.abort();
		for (client in closing) client.abort();
		entries.resize(0); closing.resize(0);
	}
}
