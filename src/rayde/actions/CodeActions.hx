package rayde.actions;

import rayde.actions.CodeAction;

private typedef Provider = {
	key:String, owner:String, id:String, languages:Array<String>, extensions:Array<String>, kinds:Array<String>, automatic:Bool,
	request:ActionRequest->Void, execute:(ActionContext, CodeAction)->Void, cancel:Null<String->Void>
};
private typedef Pending = {provider:Provider, deadline:Float};

/** Per-window, asynchronous providers. Only the current document and its current results are retained. */
class CodeActions {
	final providers = new Map<String, Provider>();
	final pending = new Map<String, Pending>();
	var context:Null<ActionContext>;
	var items:Array<ActionItem> = [];
	final weights = new Map<String, Int>();
	var totalWeight = 0;
	var serial = 0;
	public var onChanged:Null<Void->Void>;
	public var onProvidersChanged:Null<Void->Void>;
	public var onError:Null<(String, String)->Void>;
	public var clock:Void->Float = haxe.Timer.stamp;
	public function new() {}

	public function register(owner:String, data:Dynamic, request:ActionRequest->Void, execute:(ActionContext, CodeAction)->Void, ?cancel:String->Void):String {
		var id = identifier(data, "id"), key = owner + "#" + id;
		var languages = strings(data, "languages"), extensions = strings(data, "extensions"), kinds = strings(data, "kinds");
		if (languages.length == 0 && extensions.length == 0) throw "A code-action provider needs languages or extensions";
		if (Lambda.count(providers) - (providers.exists(key) ? 1 : 0) >= 64 || Lambda.count(providers, p -> p.owner == owner && p.key != key) >= 16)
			throw "Code-action providers are limited to 16 per owner and 64 per window";
		remove(key);
		providers.set(key, {key:key, owner:owner, id:id, languages:languages, extensions:extensions, kinds:kinds,
			automatic:Reflect.field(data, "automatic") == true, request:request, execute:execute, cancel:cancel});
		providersChanged(); return key;
	}

	public function unregister(owner:String, id:String):Void {
		var key = providers.exists(id) ? id : owner + "#" + id, p = providers.get(key);
		if (p != null && p.owner == owner) { remove(key); providersChanged(); }
	}
	public function release(owner:String):Void {
		var found = [for (p in providers) if (p.owner == owner) p.key];
		for (key in found) remove(key);
		if (found.length > 0) providersChanged();
	}
	function remove(key:String):Void {
		for (token in [for (t => p in pending) if (p.provider.key == key) t]) cancelRequest(token);
		providers.remove(key); items = [for (i in items) if (i.provider != key) i];
		if (weights.exists(key)) { totalWeight -= weights.get(key); weights.remove(key); }
	}
	function providersChanged():Void { changed(); if (onProvidersChanged != null) onProvidersChanged(); }

	/** Replaces the active session. A reply from any older request can no longer publish or execute. */
	public function request(value:ActionContext):Bool {
		clear();
		if (value.text.length > 4 * 1024 * 1024) return false;
		if (!validRange(value.range, value.text.length)) throw "Invalid code-action selection";
		context = snapshot(value);
		var dispatch:Array<{provider:Provider, request:ActionRequest}> = [];
		for (p in providers) if (matches(p, value)) {
			var token = "action-" + ++serial;
			pending.set(token, {provider:p, deadline:clock() + 4});
			dispatch.push({provider:p, request:{request:token, provider:p.id, context:snapshot(context)}});
		}
		changed();
		for (d in dispatch) if (pending.exists(d.request.request)) try d.provider.request(d.request) catch (e:Dynamic) {
			pending.remove(d.request.request); error(d.provider.owner, Std.string(e)); changed();
		}
		return true;
	}
	function matches(p:Provider, c:ActionContext):Bool {
		var ext = haxe.io.Path.extension(c.path).toLowerCase();
		return (c.trigger != "automatic" || p.automatic) && (p.languages.indexOf(c.language.toLowerCase()) >= 0 || p.extensions.indexOf(ext) >= 0);
	}

	/** Replies are accepted once, from their owner, before the deadline, for the current snapshot only. */
	public function respond(owner:String, token:String, value:Dynamic):Bool {
		var p = pending.get(token);
		if (p == null || p.provider.owner != owner) return false;
		pending.remove(token);
		if (context == null || clock() >= p.deadline) { cancel(p, token); changed(); return false; }
		try {
			if (!Std.isOfType(value, Array) || (value:Array<Dynamic>).length > 128) throw "A provider may return at most 128 actions";
			var next:Array<ActionItem> = [], ids = new Map<String, Bool>();
			for (raw in (value:Array<Dynamic>)) {
				var action = validate(raw, context);
				if (ids.exists(action.id)) throw "Code-action ids must be unique within a reply";
				if (p.provider.kinds.length > 0 && !Lambda.exists(p.provider.kinds, k -> action.kind == k || StringTools.startsWith(action.kind, k + "."))) throw "Action kind was not declared by its provider";
				ids.set(action.id, true); next.push({key:p.provider.key + "/" + action.id, provider:p.provider.key, action:action});
			}
			if (items.length + next.length > 512) throw "A document may have at most 512 code actions";
			var weight = haxe.Json.stringify(next).length;
			if (weight > 1024 * 1024 || totalWeight + weight > 4 * 1024 * 1024) throw "Code-action results exceed the document's 4 MiB budget";
			weights.set(p.provider.key,weight); totalWeight += weight;
			items = items.concat(next);
			items.sort((a, b) -> a.action.range.from != b.action.range.from ? a.action.range.from - b.action.range.from : a.action.preferred != b.action.preferred ? (a.action.preferred == true ? -1 : 1) : Reflect.compare(a.key, b.key));
		} catch (e:Dynamic) { error(owner, Std.string(e)); changed(); throw e; }
		changed(); return true;
	}

	public function list():Array<ActionItem> return [for (i in items) {key:i.key,provider:i.provider,action:copyAction(i.action)}];
	public function busy():Bool return Lambda.count(pending) > 0;
	public function count():Int return Lambda.count(providers);
	public function current(path:String, version:Int):Bool return context != null && context.path == path && context.version == version;
	public function contextFor(owner:String, token:String):Null<ActionContext> {
		var p = pending.get(token);
		return p == null || p.provider.owner != owner || context == null || p.deadline <= clock() ? null : snapshot(context);
	}
	public function reject(owner:String, token:String, message:String):Void {
		var p = pending.get(token); if (p == null || p.provider.owner != owner) return;
		pending.remove(token); error(owner,message); changed();
	}
	public function expire():Void {
		var due = [for (token => p in pending) if (p.deadline <= clock()) token];
		for (token in due) cancelRequest(token);
		if (due.length > 0) changed();
	}
	public function delay():Null<Float> {
		var left:Null<Float> = null;
		for (p in pending) if (left == null || p.deadline - clock() < left) left = Math.max(0, p.deadline - clock());
		return left;
	}

	/** Consume once, validate again, then apply an atomic edit before invoking the owning provider's command. */
	public function execute(key:String, path:String, version:Int, apply:(ActionContext, CodeAction)->Bool):Bool {
		if (!current(path, version)) return false;
		var item = Lambda.find(items, i -> i.key == key), p = item == null ? null : providers.get(item.provider);
		if (p == null || item.action.disabled != null) return false;
		var saved = snapshot(context), action = copyAction(item.action);
		clear();
		if (!apply(saved, action)) return false;
		p.execute(saved, action); return true;
	}
	public function clear():Void {
		for (token in [for (t in pending.keys()) t]) cancelRequest(token);
		context = null; items = []; weights.clear(); totalWeight = 0; changed();
	}
	public function dispose():Void {
		onChanged = null; onProvidersChanged = null; clear(); providers.clear(); onError = null;
	}
	function cancelRequest(token:String):Void { var p = pending.get(token); pending.remove(token); if (p != null) cancel(p, token); }
	function cancel(p:Pending, token:String):Void { if (p.provider.cancel != null) try p.provider.cancel(token) catch (e:Dynamic) error(p.provider.owner, Std.string(e)); }
	function changed():Void { if (onChanged != null) onChanged(); }
	function error(owner:String, message:String):Void { if (onError != null) onError(owner, message); }

	static function validate(raw:Dynamic, c:ActionContext):CodeAction {
		var range:ActionRange = raw.range == null ? copy(c.range) : {from:integer(raw.range, "from"), to:integer(raw.range, "to")};
		if (!validRange(range, c.text.length) || !boundary(c.text,range.from) || !boundary(c.text,range.to)) throw "Code-action range is outside the document or splits a Unicode character";
		var action:CodeAction = {id:identifier(raw, "id"), title:text(raw, "title", 160), kind:text(raw, "kind", 80), range:range};
		if (raw.icon != null) action.icon = text(raw, "icon", 80);
		if (raw.disabled != null) action.disabled = text(raw, "disabled", 240);
		action.preferred = raw.preferred == true;
		if (raw.command != null) action.command = text(raw, "command", 120);
		if (raw.arguments != null) { var json = haxe.Json.stringify(raw.arguments); if (json.length > 32768) throw "Code-action arguments exceed 32 KiB"; action.arguments = haxe.Json.parse(json); }
		if (raw.edits != null) {
			if (!Std.isOfType(raw.edits, Array) || (raw.edits:Array<Dynamic>).length > 128) throw "Code-action edits must be an array of at most 128 edits";
			var edits:Array<ActionEdit> = [], size = 0;
			for (edit in (raw.edits:Array<Dynamic>)) {
				var e = {from:integer(edit, "from"), to:integer(edit, "to"), text:text(edit, "text", 256 * 1024, true)};
				if (!validRange(e, c.text.length) || !boundary(c.text,e.from) || !boundary(c.text,e.to)) throw "Code-action edit is outside the document or splits a Unicode character";
				size += e.text.length; edits.push(e);
			}
			if (size > 256 * 1024) throw "Code-action inserted text exceeds 256 KiB";
			edits.sort((a, b) -> a.from != b.from ? a.from - b.from : a.to - b.to);
			for (i in 1...edits.length) if (edits[i].from < edits[i - 1].to || edits[i].from == edits[i - 1].from) throw "Code-action edits overlap";
			action.edits = edits;
		}
		if (action.command == null && (action.edits == null || action.edits.length == 0) && action.disabled == null) throw "A code action needs a command or edits";
		return action;
	}
	static function validRange(r:ActionRange, length:Int):Bool return r != null && r.from >= 0 && r.to >= r.from && r.to <= length;
	static function boundary(text:String, at:Int):Bool return at <= 0 || at >= text.length || !(text.charCodeAt(at) >= 0xDC00 && text.charCodeAt(at) <= 0xDFFF && text.charCodeAt(at - 1) >= 0xD800 && text.charCodeAt(at - 1) <= 0xDBFF);
	static function integer(data:Dynamic, field:String):Int { var v = Reflect.field(data, field); if (!Std.isOfType(v, Int)) throw 'Code-action $field must be an integer'; return v; }
	static function identifier(data:Dynamic, field:String):String { var v = text(data, field, 80); if (!~/^[A-Za-z][A-Za-z0-9_.-]*$/.match(v)) throw 'Invalid code-action $field'; return v; }
	static function text(data:Dynamic, field:String, limit:Int, empty = false):String {
		var v = Reflect.field(data, field);
		if (!Std.isOfType(v, String) || (v:String).length > limit || !empty && StringTools.trim(v) == "") throw 'Code-action $field must be text, at most $limit characters';
		return v;
	}
	static function strings(data:Dynamic, field:String):Array<String> {
		var value:Dynamic = Reflect.field(data, field); if (value == null) return [];
		if (!Std.isOfType(value, Array) || (value:Array<Dynamic>).length > 32) throw 'Provider $field must be an array of at most 32 strings';
		return [for (v in (value:Array<Dynamic>)) text({value:v}, "value", 80).toLowerCase()];
	}
	static function copy<T>(value:T):T return haxe.Json.parse(haxe.Json.stringify(value));
	static function copyAction(a:CodeAction):CodeAction return {id:a.id,title:a.title,kind:a.kind,range:{from:a.range.from,to:a.range.to},icon:a.icon,
		preferred:a.preferred,disabled:a.disabled,command:a.command,arguments:a.arguments == null ? null : copy(a.arguments),
		edits:a.edits == null ? null : [for (e in a.edits) {from:e.from,to:e.to,text:e.text}]};
	static function snapshot(c:ActionContext):ActionContext return {path:c.path, language:c.language, text:c.text, version:c.version,
		range:{from:c.range.from,to:c.range.to}, trigger:c.trigger, diagnostics:[for (d in c.diagnostics.slice(0, 100)) {from:d.from,to:d.to,message:d.message,severity:d.severity}]};
}
