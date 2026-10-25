package rayde.workspace.session;

/** A request the session refused. `code` is stable (`not-found`, `auth-required`, `outside`…), `message` is a sentence. */
class SessionFailure {
	public final code:String;
	public final message:String;
	/** Where to sign in, when the code is `auth-required`. */
	public final login:Null<String>;

	public function new(code:String, message:String, ?login:String) {
		this.code = code;
		this.message = message;
		this.login = login;
	}

	public function toString():String return message;
}

/** One connection to a session, used synchronously: a request returns when its response has arrived, and events that come meanwhile are routed on. */
class SessionClient {
	public var root(default, null) = "";
	public var name(default, null) = "";
	public var exec(default, null) = false;
	/** Where to sign in, when the session asks for it before changes. */
	public var signin(default, null):Null<String>;
	/** Called for every event the session sends that is not a response. */
	public var onEvent:Null<Dynamic->Void>;

	final channel:Channel;
	var next = 1;
	final responses = new Map<Int, Dynamic>();

	function new(channel:Channel) {
		this.channel = channel;
	}

	/** Connects over a WebSocket to `host:port`'s `/session`. */
	public static function connect(host:String, port:Int, ?token:String):SessionClient
		return over(WebSocket.connect(host, port, "/session"), token);

	/** Connects over frames on a TCP stream, to a session's raw port. */
	public static function connectFramed(host:String, port:Int, ?token:String):SessionClient
		return over(FramedChannel.connect(host, port), token);

	/** Says hello on `channel` and returns the client for it. */
	public static function over(channel:Channel, ?token:String):SessionClient {
		var client = new SessionClient(channel);
		try {
			var hello = client.request("hello", {token: token});
			client.root = hello.root;
			client.name = hello.name;
			client.exec = hello.exec == true;
			client.signin = hello.signin;
		} catch (e:Dynamic) {
			channel.close();
			throw e;
		}
		return client;
	}

	public function request(op:String, ?params:Dynamic, timeout = 60.):Dynamic {
		var id = next++, message:Dynamic = {};
		if (params != null) for (field in Reflect.fields(params)) if (Reflect.field(params, field) != null) Reflect.setField(message, field, Reflect.field(params, field));
		Reflect.setField(message, "op", op);
		Reflect.setField(message, "id", id);
		channel.sendText(haxe.Json.stringify(message));
		var until = haxe.Timer.stamp() + timeout;
		while (!responses.exists(id)) {
			if (haxe.Timer.stamp() > until) throw new SessionFailure("timeout", "The session did not answer " + op + ".");
			pump(.5);
		}
		var reply = responses.get(id);
		responses.remove(id);
		if (reply.ok != true) throw new SessionFailure(reply.code, reply.message, reply.login);
		return reply;
	}

	/** Reads one message if one arrives within `seconds`, and routes it. Returns whether one did. */
	public function pump(seconds:Float):Bool {
		var text = channel.receive(seconds);
		if (text == null) return false;
		var message:Dynamic = haxe.Json.parse(text);
		if (message.id != null) responses.set(message.id, message);
		else if (message.ev != null && onEvent != null) onEvent(message);
		return true;
	}

	/** Takes everything that has already arrived. */
	public function drain():Void while (pump(0)) {}

	public function close():Void channel.close();
}
