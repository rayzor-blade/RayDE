package rayde.ext;

import rayde.actions.CodeActions;
import rayde.actions.CodeAction;
import rayde.actions.ActionOffsets;

/** RayScript protocol adapter. Commands stay with their owner and source stays inside the workspace. */
class CodeActionProviders {
	final actions:CodeActions;
	final root:String;
	final hook:(String, String, Dynamic)->Void;
	final command:(String, String, Dynamic)->Void;
	final grants = new Map<String, Bool>();
	public function new(actions:CodeActions, root:String, hook:(String, String, Dynamic)->Void, command:(String, String, Dynamic)->Void) {
		this.actions = actions; this.root = root; this.hook = hook; this.command = command;
	}
	public function register(owner:String, manifest:Manifest, definition:Dynamic):String {
		if (manifest == null || manifest.capabilities.indexOf("codeActions.provide") < 0 || manifest.capabilities.indexOf("workspace.read") < 0)
			throw "Code-action providers require codeActions.provide and workspace.read";
		grants.set(owner, manifest.capabilities.indexOf("workspace.write") >= 0);
		return actions.register(owner, definition, request -> {
			if (!rayde.files.FileOps.inside(root, request.context.path)) { actions.respond(owner, request.request, []); return; }
			var c = request.context, positions = [c.range.from,c.range.to];
			for (d in c.diagnostics) { positions.push(d.from); positions.push(d.to); }
			var offsets = ActionOffsets.convert(c.text,positions,false);
			c.range = {from:offsets.get(c.range.from),to:offsets.get(c.range.to)};
			for (d in c.diagnostics) { d.from = offsets.get(d.from); d.to = offsets.get(d.to); }
			hook(owner, "codeActions.request", request);
		}, (context, action) -> {
			var offsets = ActionOffsets.convert(context.text,[action.range.from,action.range.to],false);
			if (action.command != null) command(owner, action.command, {path:context.path, version:context.version, range:{from:offsets.get(action.range.from),to:offsets.get(action.range.to)}, arguments:action.arguments});
		}, token -> hook(owner, "codeActions.cancel", {request:token}));
	}
	public function respond(owner:String, token:String, values:Dynamic):Bool {
		var context = actions.contextFor(owner,token);
		if (context == null) return false;
		try {
			if (!Std.isOfType(values, Array) || (values:Array<Dynamic>).length > 128) return actions.respond(owner,token,values);
			var positions:Array<Int> = [], ranges:Array<Dynamic> = [];
			for (action in (values:Array<Dynamic>)) {
				if (action.range != null) ranges.push(action.range);
				if (action.edits != null && Std.isOfType(action.edits, Array)) {
					var edits:Array<Dynamic> = action.edits;
					if (edits.length > 128) throw "A code action may have at most 128 edits";
					if (grants.get(owner) != true && edits.length > 0) throw "Code-action edits require workspace.write";
					for (edit in edits) ranges.push(edit);
				}
			}
			for (range in ranges) for (field in ["from","to"]) {
				var value = Reflect.field(range,field); if (!Std.isOfType(value,Int)) throw "Code-action offsets must be integers"; positions.push(value);
			}
			var offsets = ActionOffsets.convert(context.text,positions,true);
			for (range in ranges) { range.from = offsets.get(range.from); range.to = offsets.get(range.to); }
			return actions.respond(owner, token, values);
		} catch (error:Dynamic) { actions.reject(owner,token,Std.string(error)); throw error; }
	}
	public function unregister(owner:String, id:String):Void actions.unregister(owner, id);
	public function release(owner:String):Void { grants.remove(owner); actions.release(owner); }
	public function invalidate(owner:String):Void {
		if (grants.exists(owner) && actions.onProvidersChanged != null) actions.onProvidersChanged();
	}
}
