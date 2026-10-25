package rayde.lang;

import rayde.workspace.Fs;

typedef TextPosition = {line:Int, character:Int};
typedef TextRange = {start:TextPosition, end:TextPosition};
typedef Location = {file:String, range:TextRange};

/** Severity as LSP numbers it: 1 error, 2 warning, 3 information, 4 hint. */
typedef Diagnostic = {file:String, range:TextRange, severity:Int, message:String};

typedef CompletionItem = {
	label:String,
	/** The compiler's kind: Local, ClassField, Type, Keyword, Literal, EnumField, Package and so on. */
	kind:String,
	/** The item's type, printed as Haxe writes it, or "" when it has none. */
	detail:String,
	documentation:Null<String>
};

typedef Completion = {items:Array<CompletionItem>, ?replace:TextRange, filter:String};
typedef Hover = {range:Null<TextRange>, type:String, documentation:Null<String>};
typedef SignatureParameter = {name:String, type:String, optional:Bool};
typedef Signature = {label:String, parameters:Array<SignatureParameter>, documentation:Null<String>};
typedef SignatureHelp = {signatures:Array<Signature>, active:Int, parameter:Int};

/** What the compiler said instead of a display reply: usually that the file does not parse. */
class DisplayError extends haxe.Exception {}

/**
 * Display requests for one project, answered by its compilation server through
 * the compiler's JSON-RPC display protocol. A request names a position by
 * byte offset into the file as UTF-8; replies give line and character. Passing
 * `contents` types the buffer as it is in the editor instead of the file on
 * disk.
 *
 * The server keeps each module as it last typed it and reuses it while the
 * file on disk is unchanged, whatever contents a request carries; so a file
 * is invalidated before a request with contents, and once more when requests
 * for it go back to the disk.
 */
class Display {
	public final server:CompilerServer;
	public final cwd:String;
	/** The compiler's arguments for the project; `reload` reads them again after the build file changes. */
	public var args(default, null):Array<String>;

	/** The build file this was read from, when it was read from one. */
	public var hxml(default, null):Null<String>;
	public var project(default, null):Null<rayde.project.ProjectFile>;

	var id = 0;

	/** Files last typed from contents rather than from disk. */
	final edited = new Map<String, Bool>();

	public function new(server:CompilerServer, cwd:String, args:Array<String>, ?hxml:String, ?project:rayde.project.ProjectFile) {
		this.server = server;
		this.cwd = cwd;
		this.args = args;
		this.hxml = hxml;
		this.project = project;
	}

	/** Reads the build file again, so requests use what it says now. Nothing happens for a project not read from one. */
	public function reload():Void
		if (project != null) { project = rayde.project.ProjectFile.read(project.file); args = project.args; hxml = project.hxml; }
		else if (hxml != null)
			args = Hxml.read(hxml);

	public static function ofProject(server:CompilerServer, file:String):Display {
		var project = rayde.project.ProjectFile.read(file);
		return new Display(server, project.root, project.args, project.hxml, project);
	}

	/** A project read from its `.hxml`, run from that file's folder. */
	public static function ofHxml(server:CompilerServer, hxml:String):Display {
		var full = Fs.fullPath(hxml);
		return new Display(server, haxe.io.Path.directory(full), Hxml.read(full), full);
	}

	/** The byte offset in `text` as UTF-8 of the character at `offset`: what a request takes where an editor has a character offset. */
	public static function byteOffset(text:String, offset:Int):Int
		return haxe.io.Bytes.ofString(text.substr(0, offset)).length;

	public function completion(file:String, offset:Int, ?contents:String, auto = false):Completion {
		var r:Dynamic = call("display/completion", place(file, offset, contents, {wasAutoTriggered: auto}));
		if (r == null)
			return {items: [], filter: ""};
		var items:Array<Dynamic> = r.items;
		return {
			items: [for (i in items) item(i)],
			replace: r.replaceRange,
			filter: r.filterString == null ? "" : r.filterString
		};
	}

	public function hover(file:String, offset:Int, ?contents:String):Null<Hover> {
		var r:Dynamic = call("display/hover", place(file, offset, contents));
		if (r == null)
			return null;
		var item:Dynamic = r.item;
		var type:Dynamic = item == null || item.type == null ? (item == null ? null : item.args == null ? null : item.args.type) : item.type;
		return {range: r.range, type: Types.print(type), documentation: r.documentation};
	}

	public function definition(file:String, offset:Int, ?contents:String):Array<Location>
		return locations(call("display/definition", place(file, offset, contents)));

	public function references(file:String, offset:Int, ?contents:String):Array<Location>
		return locations(call("display/references", place(file, offset, contents, {kind: "withBaseAndDescendants"})));

	public function signatureHelp(file:String, offset:Int, ?contents:String, auto = false):Null<SignatureHelp> {
		var r:Dynamic = call("display/signatureHelp", place(file, offset, contents, {wasAutoTriggered: auto}));
		if (r == null)
			return null;
		var list:Array<Dynamic> = r.signatures;
		return {
			signatures: [for (s in list) signature(s)],
			active: r.activeSignature,
			parameter: r.activeParameter
		};
	}

	/** What is wrong in `file`, or, without one, in every file the compiler typed. */
	public function diagnostics(?file:String, ?contents:String):Array<Diagnostic> {
		var params:Dynamic = {};
		if (file != null) {
			params.file = Fs.fullPath(file);
			fresh(params.file, contents);
		}
		if (contents != null)
			params.contents = contents;
		var r:Dynamic = call("display/diagnostics", params);
		var out:Array<Diagnostic> = [];
		if (r == null)
			return out;
		var files:Array<Dynamic> = r;
		for (f in files) {
			var list:Array<Dynamic> = f.diagnostics;
			for (d in list)
				out.push({file: f.file, range: d.range, severity: d.severity, message: Std.string(d.args)});
		}
		return out;
	}

	function place(file:String, offset:Int, contents:Null<String>, ?extra:Dynamic):Dynamic {
		var params:Dynamic = extra == null ? {} : extra;
		params.file = Fs.fullPath(file);
		params.offset = offset;
		fresh(params.file, contents);
		if (contents != null)
			params.contents = contents;
		return params;
	}

	/** Invalidates `file` when this request types it from contents, or the last one did. */
	function fresh(file:String, contents:Null<String>):Void {
		if (contents == null && !edited.exists(file))
			return;
		call("server/invalidate", {file: file});
		if (contents == null)
			edited.remove(file);
		else
			edited.set(file, true);
	}

	/** The `result` of the display request `method`, or null when there is nothing at that place. */
	function call(method:String, params:Dynamic):Dynamic {
		id++;
		var request = haxe.Json.stringify({jsonrpc: "2.0", id: id, method: method, params: params});
		var reply = server.request(cwd, args.concat(["--no-output", "--display", request]));
		var start = reply.indexOf("{");
		var json:Dynamic = try haxe.Json.parse(start < 0 ? reply : reply.substr(start)) catch (_:Dynamic) throw new DisplayError(StringTools.trim(reply));
		if (json.error != null)
			throw new DisplayError(json.error.message == null ? Std.string(json.error) : json.error.message);
		return json.result == null ? null : json.result.result;
	}

	static function locations(r:Dynamic):Array<Location> {
		if (r == null)
			return [];
		var list:Array<Dynamic> = r;
		return [for (l in list) {file: l.file, range: l.range}];
	}

	static function item(i:Dynamic):CompletionItem {
		var a:Dynamic = i.args, label = "", detail = "", doc:Null<String> = null;
		switch (i.kind : String) {
			case "ClassField" | "EnumAbstractField":
				label = a.field.name;
				detail = Types.print(a.field.type);
				doc = a.field.doc;
			case "EnumField":
				label = a.field.name;
				detail = Types.print(a.field.type);
				doc = a.field.doc;
			case "Local":
				label = a.name;
				detail = Types.print(a.type);
			case "Type":
				label = a.path.typeName;
				detail = Types.path(a.path);
				doc = a.doc;
			case "Package":
				var pack:Array<String> = a.path.pack;
				label = pack[pack.length - 1];
			case "Module":
				label = a.path.moduleName;
			case _:
				label = a != null && a.name != null ? a.name : "";
		}
		return {label: label, kind: i.kind, detail: detail, documentation: doc == null ? null : StringTools.trim(doc)};
	}

	static function signature(s:Dynamic):Signature {
		var args:Array<Dynamic> = s.args;
		var parameters = [for (a in args) {name: (a.name : String), type: Types.print(a.t), optional: a.opt == true}];
		var label = "(" + [for (p in parameters) (p.optional ? "?" : "") + p.name + ":" + p.type].join(", ") + "):" + Types.print(s.ret);
		return {label: label, parameters: parameters, documentation: s.documentation};
	}
}

/** The compiler's JSON form of a type, printed as Haxe writes it. */
class Types {
	public static function print(t:Dynamic):String {
		if (t == null)
			return "";
		var a:Dynamic = t.args;
		return switch (t.kind : String) {
			case "TInst" | "TEnum" | "TType" | "TAbstract":
				var params:Array<Dynamic> = a.params;
				a.path.typeName + (params == null || params.length == 0 ? "" : "<" + [for (p in params) print(p)].join(", ") + ">");
			case "TFun":
				var list:Array<Dynamic> = a.args;
				"(" + [for (p in list) (p.opt ? "?" : "") + (p.name == "" ? "" : p.name + ":") + print(p.t)].join(", ") + ") -> " + print(a.ret);
			case "TAnonymous":
				var fields:Array<Dynamic> = a.fields;
				"{" + [for (f in fields) f.name + ":" + print(f.type)].join(", ") + "}";
			case "TDynamic":
				a == null ? "Dynamic" : "Dynamic<" + print(a) + ">";
			case "TMono":
				a == null ? "Unknown" : print(a);
			case _:
				"?";
		}
	}

	public static function path(p:Dynamic):String {
		var pack:Array<String> = p.pack;
		return (pack.length == 0 ? "" : pack.join(".") + ".") + (p.moduleName == p.typeName ? p.typeName : p.moduleName + "." + p.typeName);
	}
}
