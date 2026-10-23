import rayde.actions.CodeActions;
import rayde.actions.CodeAction;

@:access(rayde.actions.EntryPointActions)
class CodeActionChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	static function rejects(f:Void->Void, message:String):Void { var failed = false; try f() catch (_:Dynamic) failed = true; check(failed, message); }
	static function main():Void run();
	public static function run():Void {
		for (sample in [
			{text:'class Main { public static inline function main() {} }',found:true},
			{text:'// class Main { static function main() {} }\nclass Main {}',found:false},
			{text:'class Main { var s = "static function main() {}"; function main() {} }',found:false},
			{text:'class Other { static function main() {} } class Main { static function helper() {} }',found:false},
			{text:'class Main { function helper() { var s = "}"; } static function main() {} }',found:true},
			{text:'class Main { static function main(arg:String) {} }',found:false}
		]) {
			var result = rayde.actions.EntryPointActions.scan({name:"Main",request:{request:"test",provider:"run",context:{path:"/Main.hx",language:"haxe",text:sample.text,version:1,range:{from:0,to:0},trigger:"automatic",diagnostics:[]}}},() -> false);
			check((result.range != null) == sample.found,"Run hint identified the wrong entry point: " + sample.text);
		}
		var actions = new CodeActions(), requests:Array<ActionRequest> = [], cancelled:Array<String> = [], commands = 0, now = 1.;
		actions.clock = () -> now;
		var provider = actions.register("test", {id:"fix",languages:["haxe"],kinds:["quickfix"]}, r -> requests.push(r), (_, _) -> commands++, t -> cancelled.push(t));
		function context(version = 1, trigger = "invoked"):ActionContext return {path:"/work/Main.hx",language:"haxe",text:"var n = 0;",version:version,range:{from:4,to:5},trigger:trigger,diagnostics:[]};
		function fix():Dynamic return {id:"rename",title:"Rename variable",kind:"quickfix.rename",edits:[{from:4,to:5,text:"value"}], command:"renamed", arguments:{value:"value"}};
		actions.request(context(1, "automatic")); check(requests.length == 0, "Manual provider ran automatically");
		actions.request(context()); var first = requests[0];
		check(!actions.respond("other", first.request, [fix()]) && actions.busy(), "Another owner consumed a response token");
		actions.request(context(2)); check(cancelled.indexOf(first.request) >= 0 && !actions.respond("test",first.request,[fix()]), "Superseded reply was published");
		var second = requests[1]; check(actions.respond("test", second.request, [fix()]) && !actions.respond("test", second.request, [fix()]), "Response token was reusable");
		var key = actions.list()[0].key;
		var detached = actions.list(); detached[0].action.edits[0].text = "mutated";
		check(!actions.execute(key, "/work/Main.hx", 1, (_, _) -> true) && commands == 0, "Stale version executed");
		check(actions.execute(key, "/work/Main.hx", 2, (c, a) -> a.edits[0].text == "value" && c.text == "var n = 0;") && commands == 1, "Valid action lost its snapshot or atomic edits");
		check(!actions.execute(key, "/work/Main.hx", 2, (_, _) -> true), "Action executed twice");
		actions.request(context()); now += 5; actions.expire(); check(!actions.busy() && !actions.respond("test", requests[2].request, [fix()]), "Expired reply was retained");
		var invalid:Array<Dynamic> = [
			{id:"bad",title:"Bad",kind:"quickfix",edits:[{from:0,to:20,text:"x"}]},
			{id:"bad",title:"Bad",kind:"quickfix",edits:[{from:0,to:4,text:"x"},{from:3,to:5,text:"y"}]},
			{id:"bad",title:"Bad",kind:"quickfix",edits:[{from:1,to:1,text:"x"},{from:1,to:1,text:"y"}]},
			{id:"bad",title:"Bad",kind:"run",command:"run"},
			{id:"bad",title:"Bad",kind:"quickfix"}
		];
		for (bad in invalid) {
			actions.request(context()); var token = requests[requests.length - 1].request;
			rejects(() -> actions.respond("test", token, [bad]), "Invalid action was accepted");
			check(actions.list().length == 0 && !actions.busy(), "Invalid response left actions or pending requests");
		}
		actions.unregister("other", provider); check(actions.count() == 1, "Another owner removed a provider");
		actions.request(context()); actions.release("test"); check(actions.count() == 0 && !actions.busy() && actions.list().length == 0, "Owner release retained requests or actions");
		for (_ in 0...30) actions.register("test", {id:"fix",extensions:["hx"],automatic:true}, r -> requests.push(r), (_, _) -> {});
		check(actions.count() == 1, "Replacement accumulated providers");
		var oversized = context(); oversized.text = StringTools.lpad("", "x",4 * 1024 * 1024 + 1);
		check(!actions.request(oversized) && !actions.current(oversized.path,oversized.version) && !actions.busy(),"Oversized document was retained or dispatched");
		actions.request(context()); actions.dispose(); check(!actions.busy() && actions.count() == 0 && actions.list().length == 0, "Disposal retained providers or document data");
		Sys.println("code actions: selectors, opt-in hints, ownership, cancellation, deadlines, stale/duplicate replies, validation, detached data, single execution and cleanup");
	}
}
