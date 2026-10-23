package rayde.actions;

import rayde.actions.CodeAction;
import rayde.run.Worker;

private typedef Scan = {request:ActionRequest, name:String};
private typedef Found = {token:String, range:Null<ActionRange>};

/** The first built-in provider: the configured main class. Lexing happens on a data-only worker. */
class EntryPointActions {
	static inline var OWNER = "rayde.entryPoint";
	final actions:CodeActions;
	final worker = new Worker<Scan, Found>(scan);
	public function new(actions:CodeActions, isMain:String->Bool, run:Void->Void) {
		this.actions = actions;
		actions.register(OWNER, {id:"run",languages:["haxe"],kinds:["run"],automatic:true}, request -> {
			if (!isMain(request.context.path)) { actions.respond(OWNER, request.request, []); return; }
			worker.submit("main", {request:request, name:haxe.io.Path.withoutExtension(haxe.io.Path.withoutDirectory(request.context.path))});
		}, (_, _) -> run(), _ -> worker.cancel("main"));
	}
	public function tick():Void for (result in worker.poll()) if (result.value != null) {
		var v = result.value;
		actions.respond(OWNER, v.token, v.range == null ? [] : [{id:"run",title:"Run Project",kind:"run",icon:"play",range:v.range,command:"run"}]);
	}
	public function busy():Bool return worker.busy();
	public function dispose():Void { actions.release(OWNER); worker.dispose(); }
	static function scan(value:Scan, cancelled:Void->Bool):Found {
		var text = value.request.context.text, at = 0, depth = 0, classDepth = -1, classRange:Null<ActionRange> = null, stat = false;
		function token():{text:String, from:Int, to:Int} {
			while (at < text.length) {
				var c = text.charAt(at), next = text.charAt(at + 1);
				if (c == " " || c == "\t" || c == "\n" || c == "\r") { at++; continue; }
				if (c == "/" && next == "/") { var end = text.indexOf("\n", at); at = end < 0 ? text.length : end; continue; }
				if (c == "/" && next == "*") { var end = text.indexOf("*/", at + 2); at = end < 0 ? text.length : end + 2; continue; }
				if (c == '"' || c == "'" || c == "~" && next == "/") {
					var quote = c == "~" ? "/" : c; at += c == "~" ? 2 : 1;
					while (at < text.length) { var end = text.charAt(at++); if (end == "\\") at++; else if (end == quote) break; }
					continue;
				}
				var start = at++, code = c.charCodeAt(0);
				if (code == 95 || code >= 65 && code <= 90 || code >= 97 && code <= 122) while (at < text.length) {
					var n = text.charCodeAt(at); if (!(n == 95 || n >= 65 && n <= 90 || n >= 97 && n <= 122 || n >= 48 && n <= 57)) break; at++;
				}
				return {text:text.substring(start,at),from:start,to:at};
			}
			return {text:"",from:at,to:at};
		}
		while (at < text.length && !cancelled()) {
			var t = token();
			if (t.text == "class" && depth == 0) {
				var name = token(); classRange = name.text == value.name ? {from:name.from,to:name.to} : null; classDepth = -1;
			} else if (t.text == "{") { depth++; if (classRange != null && classDepth < 0) classDepth = depth; }
			else if (t.text == "}") { if (depth == classDepth) { classRange = null; classDepth = -1; } depth--; stat = false; }
			else if (depth == classDepth && classRange != null) {
				if (t.text == "static") stat = true;
				else if (t.text == ";") stat = false;
				else if (t.text == "function") {
					var name = token(), open = token(), close = token();
					if (stat && name.text == "main" && open.text == "(" && close.text == ")") return {token:value.request.request,range:classRange};
					stat = false;
				}
			}
		}
		return {token:value.request.request,range:null};
	}
}
