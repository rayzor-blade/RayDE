package rayde.workspace.session;

/** A request the session refused. `code` is stable; `message` is a sentence. */
class SessionFailure {
	public final code:String;
	public final message:String;
	public final login:Null<String>;
	public function new(code:String, message:String, ?login:String) { this.code = code; this.message = message; this.login = login; }
	public function toString():String return message;
}

private typedef Waiting = {future:ash.Future<Dynamic>, deadline:Float, op:String};

/** Multiplexed session RPC. One receiver completes futures; UI consumers drain events without waiting. */
class SessionClient {
	public var root(default, null) = "";
	public var name(default, null) = "";
	public var exec(default, null) = false;
	public var syntax(default, null) = false;
	public var terminal(default,null) = false;
	public var terminalProfiles(default,null):Array<rayde.term.Profiles.Profile> = [];
	public var remote(default, null) = true;
	public var demo(default, null) = false;
	public var repositories(default, null) = false;
	public var documentBridge(default, null) = false;
	public var storageKey(default, null):Null<String>;
	public var project(default, null):Null<String>;
	public var extensionHost(default, null):Null<String>;
	public var extensionsRoot(default, null):Null<String>;
	public var signin(default, null):Null<String>;
	public var onEvent:Null<Dynamic->Void>;
	public var onWake:Null<Void->Void>;
	final listeners:Array<Dynamic->Void> = [];
	final programs:Array<Dynamic->Void> = [];
	final channel:Channel;
	final mutex = new sys.thread.Mutex();
	final changed = new sys.thread.Lock();
	final sendWake = new sys.thread.Lock();
	var outgoing:Array<{text:String, id:Null<Int>}> = [];
	var outgoingBytes = 0;
	final waiting = new Map<Int, Waiting>();
	var events:Array<{message:Dynamic, size:Int}> = [];
	var eventBytes = 0;
	var next = 1;
	var nextWait = -1;
	var closed = false;
	var online = true;
	var generation = 0;

	function new(channel:Channel) {
		this.channel = channel;
		sys.thread.Thread.create(receive);
		sys.thread.Thread.create(deadlines);
		sys.thread.Thread.create(transmit);
	}

	public static function connect(host:String, port:Int, ?token:String):SessionClient return over(WebSocket.connect(host, port, "/session"), token);
	public static function connectFramed(host:String, port:Int, ?token:String):SessionClient return over(FramedChannel.connect(host, port), token);

	public static function over(channel:Channel, ?token:String):SessionClient {
		var client = new SessionClient(channel);
		try {
			var hello = client.request("hello", {token:token});
			client.root = hello.root; client.name = hello.name; client.exec = hello.exec == true;
			client.syntax = hello.syntax == true;client.terminal = hello.terminal == true;
			if (Std.isOfType(hello.terminalProfiles,Array)) client.terminalProfiles = cast hello.terminalProfiles;
			client.repositories = hello.repositories == true; client.demo = hello.demo == true; client.remote = hello.remote != false; client.project = hello.project; client.signin = hello.signin;
			client.documentBridge = hello.documentBridge == true; client.storageKey = hello.storageKey;
			if (Std.isOfType(hello.generation,Int)) client.generation = hello.generation;
			client.extensionHost = hello.extensions == null ? null : hello.extensions.host;
			client.extensionsRoot = hello.extensions == null ? null : hello.extensions.root;
		} catch (error:Dynamic) { client.close(); throw error; }
		return client;
	}

	public function isClosed():Bool { mutex.acquire(); var value = closed; mutex.release(); return value; }
	public function isOnline():Bool { mutex.acquire(); var value = !closed && online; mutex.release(); return value; }
	public function connectionEpoch():Int { mutex.acquire(); var value = generation; mutex.release(); return value; }

	public function subscribe(listener:Dynamic->Void):Void->Void {
		mutex.acquire(); listeners.push(listener); mutex.release();
		return () -> { mutex.acquire(); listeners.remove(listener); mutex.release(); };
	}

	/** Program and terminal streams are consumed on the receiver, where their futures can wake readers without a UI frame. */
	public function subscribePrograms(listener:Dynamic->Void):Void->Void {
		mutex.acquire(); programs.push(listener); mutex.release();
		return () -> { mutex.acquire(); programs.remove(listener); mutex.release(); };
	}

	/** Sends without waiting for a response. Page storage uses this after a local write. */
	public function notify(op:String, params:Dynamic):Void {
		var message:Dynamic = {op:op};
		if (params != null) for (field in Reflect.fields(params)) Reflect.setField(message, field, Reflect.field(params, field));
		send(message);
	}

	function send(message:Dynamic):Void {
		var text = haxe.Json.stringify(message);
		mutex.acquire();
		if (closed || outgoingBytes + text.length > 32 * 1024 * 1024) { mutex.release(); throw "The session send queue is unavailable."; }
		outgoing.push({text:text, id:message.id}); outgoingBytes += text.length;
		mutex.release(); sendWake.release();
	}

	function transmit():Void {
		try while (true) {
			mutex.acquire();
			if (closed) { mutex.release(); return; }
			var next = outgoing.shift();
			if (next != null) outgoingBytes -= next.text.length;
			var expired = next != null && next.id != null && !waiting.exists(next.id);
			mutex.release();
			if (next == null) sendWake.wait();
			else if (!expired) channel.sendText(next.text);
		} catch (error:Dynamic) { finish(error); }
	}

	/** Starts an RPC without occupying the caller until its answer; failures reject the future. */
	public function requestAsync(op:String, ?params:Dynamic, timeout = 60.):ash.Future<Dynamic> {
		var future = new ash.Future<Dynamic>(), message:Dynamic = {};
		if (params != null) for (field in Reflect.fields(params)) if (Reflect.field(params, field) != null) Reflect.setField(message, field, Reflect.field(params, field));
		mutex.acquire();
		if (closed) { mutex.release(); future.reject(new SessionFailure("closed", "The session connection is closed.")); return future; }
		if ((StringTools.startsWith(op,"proc.") || StringTools.startsWith(op,"term.")) && params != null && params.sessionGeneration != null && (!online || params.sessionGeneration != generation)) {
			mutex.release(); future.reject(new SessionFailure("stale-process","The program belongs to a disconnected session.")); return future;
		}
		if (Lambda.count(waiting) >= 4096) { mutex.release(); future.reject(new SessionFailure("busy", "Too many session requests are waiting.")); return future; }
		var id = next++;
		waiting.set(id, {future:future, deadline:haxe.Timer.stamp() + timeout, op:op});
		mutex.release(); changed.release();
		Reflect.setField(message, "op", op); Reflect.setField(message, "id", id);
		try send(message) catch (error:Dynamic) {
			mutex.acquire(); waiting.remove(id); mutex.release(); future.reject(error);
		}
		return future;
	}

	/** Synchronous provider compatibility; Ash parks this fiber while the receiver completes the RPC. */
	public function request(op:String, ?params:Dynamic, timeout = 60.):Dynamic return requestAsync(op, params, timeout).await();

	function receive():Void {
		try while (true) {
			mutex.acquire(); var stop = closed; mutex.release(); if (stop) return;
			var text = channel.receive(3600);
			if (text == null) continue;
			var message:Dynamic = haxe.Json.parse(text);
			var completions:Array<ash.Future<Dynamic>> = [];
			mutex.acquire();
			if (message.ev == "session.disconnected") {
				if (Std.isOfType(message.generation,Int)) generation = message.generation; else if (online) generation++;
				online = false;
			} else if (message.ev == "session.connected") {
				if (Std.isOfType(message.generation,Int)) generation = message.generation;
				online = true;
			}
			if (message.id != null) {
				var pending = waiting.get(message.id); waiting.remove(message.id); mutex.release(); changed.release();
				if (pending != null) {
					if (message.ok == true) pending.future.resolve(message);
					else pending.future.reject(new SessionFailure(message.code, message.message, message.login));
				}
				if (onWake != null) onWake();
			} else {
				var stream = message.ev == "proc.out" || message.ev == "proc.exit" || (message.ev != null && StringTools.startsWith(message.ev,"term.")) || message.ev == "session.disconnected";
				var consumers = stream ? programs.copy() : [];
				var queued = message.ev != null && (!stream || consumers.length == 0 || message.ev == "session.disconnected");
				if (queued) {
					if (eventBytes + text.length > 32 * 1024 * 1024) { mutex.release(); throw "The session event queue is full."; }
					events.push({message:message, size:text.length}); eventBytes += text.length;
					for (id in [for (id in waiting.keys()) if (id < 0) id]) { completions.push(waiting.get(id).future); waiting.remove(id); }
				}
				mutex.release();
				for (consumer in consumers) consumer(message);
				for (future in completions) future.resolve(true);
				if (message.ev != null && onWake != null) onWake();
			}
		} catch (error:Dynamic) { finish(error); }
	}

	/** One sleeping deadline worker per connection; no timer or poll runs while there are no pending requests. */
	function deadlines():Void {
		while (true) {
			var now = haxe.Timer.stamp(), delay:Null<Float> = null, expired:Array<Waiting> = [];
			mutex.acquire();
			if (closed) { mutex.release(); return; }
			for (id in [for (id in waiting.keys()) id]) {
				var item = waiting.get(id), remaining = item.deadline - now;
				if (remaining <= 0) { expired.push(item); waiting.remove(id); }
				else if (delay == null || remaining < delay) delay = remaining;
			}
			mutex.release();
			for (item in expired) if (item.op == "_event") item.future.resolve(false) else item.future.reject(new SessionFailure("timeout", "The session did not answer " + item.op + "."));
			if (expired.length > 0 && onWake != null) onWake();
			changed.wait(delay);
		}
	}

	/** Dispatches one event, optionally awaiting its arrival as a future. With zero seconds the UI never waits. */
	public function pump(seconds:Float):Bool {
		mutex.acquire(); var event = events.shift(); if (event != null) eventBytes -= event.size;
		if (event == null && seconds > 0 && !closed) {
			var future = new ash.Future<Dynamic>(), id = nextWait--;
			waiting.set(id, {future:future, deadline:haxe.Timer.stamp() + seconds, op:"_event"});
			mutex.release(); changed.release();
			future.await();
			return pump(0);
		}
		var callbacks = listeners.copy();
		mutex.release();
		if (event == null) return false;
		if (onEvent != null) onEvent(event.message);
		for (listener in callbacks) listener(event.message);
		return true;
	}

	public function drain():Void while (pump(0)) {}

	function finish(error:Dynamic):Void {
		mutex.acquire();
		if (closed) { mutex.release(); return; }
		closed = true;
		if (online) generation++;
		online = false;
		var pending = [for (item in waiting) item.future]; waiting.clear();
		outgoing = []; outgoingBytes = 0;
		var message = {ev:"session.disconnected"};
		events.push({message:message, size:0});
		var consumers = programs.copy();
		mutex.release(); changed.release(); sendWake.release();
		for (future in pending) future.reject(error);
		for (consumer in consumers) consumer(message);
		try channel.close() catch (_:Dynamic) {}
		if (onWake != null) onWake();
	}

	public function close():Void {
		finish(new SessionFailure("closed", "The session connection is closed."));
	}
}
