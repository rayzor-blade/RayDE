package rayde.ext;

/** Diagnostic summaries keep file contents and transport payloads out of retained activity history. */
class ActivityLog {
	public static inline var LIMIT = 2048;
	public static function clip(text:String):String
		return text.length <= LIMIT ? text : text.substr(0, LIMIT - 32) + '… (${text.length} characters)';

	public static function describe(value:Dynamic):String {
		var remaining = 64;
		function summarize(value:Dynamic, depth:Int):Dynamic {
			if (remaining-- <= 0 || depth >= 4) return "…";
			if (value == null || Std.isOfType(value, Bool) || Std.isOfType(value, Int) || Std.isOfType(value, Float)) return value;
			if (Std.isOfType(value, String)) {
				var text:String = value;
				return text.length <= 256 ? text : text.substr(0, 256) + '… (${text.length} characters)';
			}
			if (Std.isOfType(value, Array)) {
				var items:Array<Dynamic> = value, result:Array<Dynamic> = [];
				for (i in 0...Std.int(Math.min(16, items.length))) { if (remaining <= 0) break; result.push(summarize(items[i], depth + 1)); }
				if (result.length < items.length) result.push('… (${items.length} items)');
				return result;
			}
			var fields = Reflect.fields(value), result:Dynamic = {}, count = 0;
			for (field in fields) {
				if (count >= 16 || remaining <= 0) break;
				Reflect.setField(result, field.substr(0, 256), summarize(Reflect.field(value, field), depth + 1)); count++;
			}
			if (count < fields.length) Reflect.setField(result, "…", '${fields.length} fields');
			return result;
		}
		return clip(haxe.Json.stringify(summarize(value, 0)));
	}
}
