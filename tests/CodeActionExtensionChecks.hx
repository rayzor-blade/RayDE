import rayde.actions.CodeActions;
import rayde.actions.CodeAction;
import rayde.ext.CodeActionProviders;
import rayde.ext.Manager;
import rayde.ext.Manifest;

class CodeActionExtensionChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	static function main():Void run();
	public static function run():Void {
		var root = Sys.getCwd() + "bin/code-action-ext-" + Std.random(0x3fffffff), actions = new CodeActions();
		for (path in [root + "/app/actions",root + "/user",root + "/workspace"]) sys.FileSystem.createDirectory(path);
		for (name in ["actions.rayext","main.rays"]) sys.io.File.copy("tests/fixtures/codeactions/" + name,root + "/app/actions/" + name);
		var manager = new Manager(root + "/workspace",{builtins:root + "/app",user:root + "/user",defaultEvents:["onStartup"],restartLimit:3,restartWindow:60});
		var bridge = new CodeActionProviders(actions,root + "/workspace",(owner,name,data) -> {
			var entry = Lambda.find(manager.extensions,e -> e.connection.file == owner); if (entry != null) entry.connection.hook(name,data);
		},(owner,command,args) -> {
			var entry = Lambda.find(manager.extensions,e -> e.connection.file == owner); if (entry != null) entry.connection.command(command,args);
		});
		var services:rayde.ext.Connection.WorkspaceServices = {root:() -> root + "/workspace",activeFile:() -> null,readFile:_ -> null,openFile:_ -> {},writeFile:(_,_) -> {},replay:_ -> null,
			registerCodeActions:bridge.register,unregisterCodeActions:bridge.unregister,respondCodeActions:bridge.respond,invalidateCodeActions:bridge.invalidate,releaseCodeActions:bridge.release};
		function wait(done:Void->Bool):Void {
			var end = haxe.Timer.stamp() + 6;
			while (!done() && haxe.Timer.stamp() < end) { manager.tick(); Sys.sleep(.005); }
			check(done(),"Code-action extension timed out: " + [for(e in manager.extensions) e.output.join("\n")].join("\n"));
		}
		function context(version=1):ActionContext return {path:root + "/workspace/Main.hx",language:"haxe",text:"var n = 0;",version:version,range:{from:8,to:9},trigger:"invoked",diagnostics:[]};
		try {
			manager.discover(services,[]); manager.start();
			check(actions.count() == 0 && manager.extensions[0].activation == null,"Code-action extension started before its language was needed");
			manager.codeActions("haxe"); wait(() -> actions.count() == 1);
			var entry = manager.extensions[0], owner = entry.connection.file;
			check(entry.activation == "onCodeActions:haxe" && entry.connection.manifest.problems.length == 0,"Language action activation was rejected");
			actions.request(context()); wait(() -> !actions.busy());
			check(actions.list().length == 1 && actions.list()[0].action.edits[0].text == "1","Real RayScript hook did not return edits");
			check(actions.execute(actions.list()[0].key,context().path,1,(_,a) -> a.edits.length == 2),"Returned action did not execute");
			wait(() -> entry.output.join("\n").indexOf("completed:1:") >= 0);
			var unicode = context(); unicode.text = "// 🌍\nvar n = 0;"; unicode.range = {from:unicode.text.indexOf("0"),to:unicode.text.indexOf("0") + 1};
			actions.request(unicode); wait(() -> !actions.busy());
			check(actions.list().length == 1 && actions.list()[0].action.edits[0].from == unicode.text.indexOf("0") && actions.list()[0].action.edits[1].from == unicode.text.length,"RayScript Unicode positions did not map to editor offsets");
			var invalidations = 0; actions.onProvidersChanged = () -> invalidations++;
			manager.command(entry.installed.id,"invalidate",{}); wait(() -> invalidations > 0);
			actions.request(context(2)); actions.request(context(3)); wait(() -> !actions.busy());
			check(actions.current(context().path,3) && actions.list().length == 1,"Superseded extension response replaced the current document");
			wait(() -> entry.output.join("\n").indexOf("cancelled:action-") >= 0);
			actions.request(context(4)); entry.connection.stop(); check(actions.count() == 0 && !actions.busy(),"Stopped host retained providers or requests");
			entry.connection.start(); wait(() -> actions.count() == 1);
			var outside = context(); outside.path = root + "/outside.hx"; actions.request(outside);
			check(!actions.busy() && actions.list().length == 0,"Provider received source outside its workspace");
			manager.setDisabled(entry.installed.id,true); check(actions.count() == 0,"Disabled host retained providers");
			manager.setDisabled(entry.installed.id,false); manager.codeActions("haxe"); wait(() -> actions.count() == 1);
			var manifest = entry.connection.manifest, json:Dynamic = haxe.Json.parse(sys.io.File.getContent(manifest.file));
			json.capabilities = ["codeActions.provide","workspace.read"]; sys.io.File.saveContent(manifest.file,haxe.Json.stringify(json));
			entry.connection.useManifest(Manifest.read(manifest.file)); check(actions.count() == 0,"Revoked write grant retained editable actions");
			entry.connection.stop(); entry.connection.start(); wait(() -> actions.count() == 1);
			actions.request(context()); wait(() -> entry.output.join("\n").indexOf("Code-action edits require workspace.write") >= 0);
			actions.clear();
			json.capabilities = []; sys.io.File.saveContent(manifest.file,haxe.Json.stringify(json)); entry.connection.useManifest(Manifest.read(manifest.file));
			check(actions.count() == 0,"Revoked provide/read grant retained providers");
			entry.connection.stop(); entry.connection.start(); wait(() -> entry.output.join("\n").indexOf("Capabilities codeActions.provide and workspace.read are required") >= 0);
		} catch(error:Dynamic) { manager.dispose(); actions.dispose(); throw error; }
		manager.dispose(); check(actions.count() == 0,"Manager disposal retained registrations"); actions.dispose();
		Sys.println("extension code actions: real RayScript activation, hooks, edits, owner commands, cancellation, source scope, invalidation, revocation and cleanup");
	}
}
