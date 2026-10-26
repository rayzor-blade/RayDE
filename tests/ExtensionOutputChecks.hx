import rayde.ext.Connection;
import rayde.ext.Connection.HostEntry;
import rayde.ext.ExtensionHost;

private class OutputHost extends ExtensionHost {
	public var messages:Array<Dynamic>;
	public function new(messages:Array<Dynamic>) {
		super(null, true, "fixture");
		this.messages = messages;
	}
	override public function poll():Array<Dynamic> {
		var batch = messages; messages = []; return batch;
	}
}

@:access(rayde.ext.Connection)
class ExtensionOutputChecks {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;
	static function main():Void run();
	public static function run():Void {
		var connection = new Connection("main.rays", () -> ""), entries:Array<HostEntry> = [];
		connection.onEntry = (list, entry) -> if (list == "console") entries.push(entry);
		connection.host = new OutputHost([haxe.Json.parse('{"t":"error","kind":"runtime","message":"Missing setting\\nDetails","items":[{"file":"/work/main.rays","line":7,"col":17,"function":"start"},{"file":"/work/main.rays","line":28,"col":7,"function":"main"}]}')]);
		connection.tick();
		check(entries.length == 2, "Runtime errors must retain the message and caller");
		check(entries[0].text == "Missing setting" && entries[0].line == 7 && entries[0].col == 17, "The error lost its source location");
		check(entries[1].text == "  at main main.rays:28:7" && entries[1].line == 28, "Numeric stack locations must format as text");
		connection.host = new OutputHost([haxe.Json.parse('{"t":1}')]);
		connection.tick();
		check(connection.state == "exited" && connection.host == null, "Invalid isolated output escaped its host boundary");
		check(entries.length == 3 && entries[2].text.indexOf("Cannot process extension output:") == 0, "Invalid output had no diagnostic");
		connection.stop();
		Sys.println("Extension output: runtime stack locations and isolated protocol failure containment passed");
	}
}
