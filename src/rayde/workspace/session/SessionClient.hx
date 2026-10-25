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
	public final root:String;
	public final name:String;
	public final exec:Bool;
	/** Where to sign in, when the session asks for it before changes. */
	public final signin:Null<String>;
	/** Called for every event the session sends that is not a response. */
	public var onEvent:Null<Dynamic->Void>;

	final socket:WebSocket;
	var next = 1;
	final responses = new Map<Int, Dynamic>();

	function new(socket:WebSocket, hello:Dynamic) {
		this.socket = socket;
		root = hello.root;
		name = hello.name;
		exec = hello.exec == true;
		signin = hello.signin;
	}

	public static function connect(host:String, port:Int, ?token:String):SessionClient {
		var socket = WebSocket.connect(host, port, "/session");
		var client = new SessionClient(socket, {});
		// `hello` is the first request, so it cannot go through the constructor's answer.
		var hello = client.request("hello", {token: token});
		return new SessionClient(socket, hello);
	}

	public function request(op:String, ?params:Dynamic, timeout = 60.):Dynamic {
		var id = next++, message:Dynamic = {};
		if (params != null) for (field in Reflect.fields(params)) if (Reflect.field(params, field) != null) Reflect.setField(message, field, Reflect.field(params, field));
		Reflect.setField(message, "op", op);
		Reflect.setField(message, "id", id);
		socket.sendText(haxe.Json.stringify(message));
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
		var text = socket.receive(seconds);
		if (text == null) return false;
		var message:Dynamic = haxe.Json.parse(text);
		if (message.id != null) responses.set(message.id, message);
		else if (message.ev != null && onEvent != null) onEvent(message);
		return true;
	}

	/** Takes everything that has already arrived. */
	public function drain():Void while (pump(0)) {}

	public function close():Void socket.close();
}
