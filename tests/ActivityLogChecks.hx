import rayde.ext.ActivityLog;
import rayde.ext.Connection;
import rayde.ext.Studio;

private class RecordedConnection extends Connection {
	public var sent:Array<Dynamic> = [];
	public function new() super("test.rays", () -> "");
	override public function send(message:Dynamic):Bool { sent.push(message); return true; }
}

@:access(rayde.ext.Connection)
@:access(rayde.ext.Studio)
class ActivityLogChecks {
	static function main():Void run();
	public static function run():Void {
		var source = [for (_ in 0...20000) 'source text with "quotes" and \\ escapes\n'].join("");
		var connection = new RecordedConnection(), entries:Array<String> = [];
		connection.onEntry = (list, entry) -> if (list == "activity") entries.push(entry.text);
		connection.services = {readFile:_ -> source, activeFile:() -> null, root:() -> ".", openFile:_ -> {}, writeFile:(_, _) -> {}, replay:_ -> null};
		connection.answer({fn:"rayde.workspace.readFile", id:1, args:["large.md"]});
		if (connection.sent.length != 1 || connection.sent[0].value != source) throw "Activity summary changed the file reply";
		for (entry in entries) if (entry.length > ActivityLog.LIMIT + 64 || entry.indexOf(source) >= 0) throw "Activity retained a complete file reply";
		if (entries[entries.length - 1].indexOf("characters") < 0) throw "Activity did not explain the shortened reply";
		var cycle:Dynamic = {}; cycle.self = cycle;
		if (ActivityLog.describe(cycle).length > ActivityLog.LIMIT || ActivityLog.describe([for (_ in 0...10000) {payload:source}]).length > ActivityLog.LIMIT) throw "Nested or cyclic diagnostics grew without bound";
		if (ActivityLog.describe({ok:true, count:3}) != haxe.Json.stringify({ok:true, count:3})) throw "Small diagnostics changed";
		var tree = new ashui.layout.LayoutTree(), studio = new Studio("test.rays", () -> "", tree, null, connection);
		var longEntry = source.substr(0, ActivityLog.LIMIT + 100);
		for (i in 0...1100) studio.note(studio.activity, "event", '$i: $longEntry');
		var history = studio.activity.get(), chars = 0;
		for (entry in history) { chars += entry.text.length; if (entry.text.length > ActivityLog.LIMIT) throw "Activity bypassed its entry limit"; }
		if (history.length != 1000 || chars > 1000 * ActivityLog.LIMIT || !StringTools.startsWith(history[0].text, "100:") || !StringTools.startsWith(history[999].text, "1099:")) throw "Activity history lost its bounded chronological tail";
		studio.dispose(); tree.dispose();
		Sys.println("activity: full service replies, bounded file/nested/cyclic summaries and bounded chronological history");
	}
}
