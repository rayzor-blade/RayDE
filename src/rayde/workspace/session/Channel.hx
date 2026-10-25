package rayde.workspace.session;

/** Whole text messages to and from a session, however they travel. */
interface Channel {
	function sendText(text:String):Void;
	/** The next message, waiting up to `seconds` for one to start; null when none does. Throws when the connection has ended. */
	function receive(seconds:Float):Null<String>;
	function close():Void;
}
