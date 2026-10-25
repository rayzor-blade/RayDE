package rayde.lang;

import ashui.components.code.CodeHistory.CodeEdit;

typedef DocumentEdits = {file:String, version:Null<Int>, edits:Array<Dynamic>};

/** Text-only workspace edits, checked completely before any editor buffer is changed. */
class WorkspaceEdits {
	public static function documents(value:Dynamic):Array<DocumentEdits> {
		if (value == null)
			return [];
		if (value.changeAnnotations != null)
			for (id in Reflect.fields(value.changeAnnotations))
				if (Reflect.field(value.changeAnnotations, id).needsConfirmation == true)
					throw "This edit requires change confirmation.";
		var result:Array<DocumentEdits> = [];
		function add(uri:String, version:Null<Int>, edits:Dynamic):Void {
			var file = uri == null ? null : LspProtocol.path(uri);
			if (file == null || !Std.isOfType(edits, Array))
				throw "Invalid workspace text edit.";
			if (Lambda.exists(result, item -> item.file == file))
				throw "Repeated document edits are not supported.";
			result.push({file: file, version: version, edits: edits});
		}
		if (value.documentChanges != null) {
			if (!Std.isOfType(value.documentChanges, Array))
				throw "Invalid document changes.";
			for (item in (value.documentChanges : Array<Dynamic>)) {
				if (item == null || item.kind != null || item.textDocument == null)
					throw "This edit requires a file creation, rename or deletion.";
				add(item.textDocument.uri, item.textDocument.version, item.edits);
			}
		} else if (value.changes != null)
			for (uri in Reflect.fields(value.changes))
				add(uri, null, Reflect.field(value.changes, uri));
		return result;
	}

	public static function edits(text:String, values:Array<Dynamic>):Array<CodeEdit> {
		function offset(position:Dynamic):Int {
			if (position == null
				|| !Std.isOfType(position.line, Int)
				|| !Std.isOfType(position.character, Int)
				|| position.line < 0
				|| position.character < 0)
				throw "Invalid text edit position.";
			var at = LspProtocol.offset(text, position),
				actual = LspProtocol.position(text, at);
			if (actual.line != position.line || actual.character != position.character)
				throw "Text edit is outside the document.";
			return at;
		}
		var pending = [];
		for (item in values) {
			if (item == null || item.range == null || !Std.isOfType(item.newText, String))
				throw "Invalid text edit.";
			var from = offset(item.range.start), to = offset(item.range.end);
			if (to < from)
				throw "Invalid text edit range.";
			pending.push({
				from: from,
				to: to,
				text: (item.newText : String),
				order: pending.length
			});
		}
		pending.sort((a, b) -> a.from != b.from ? a.from - b.from : a.to != b.to ? a.to - b.to : a.order - b.order);
		var result:Array<CodeEdit> = [];
		var end = 0;
		for (edit in pending) {
			if (edit.from < end)
				throw "Text edits overlap.";
			var last = result.length == 0 ? null : result[result.length - 1];
			if (last != null && edit.from == edit.to && last.from == edit.from && last.to == edit.to)
				result[result.length - 1] = {from: edit.from, to: edit.to, text: last.text + edit.text};
			else
				result.push({from: edit.from, to: edit.to, text: edit.text});
			end = edit.to;
		}
		return result;
	}

	public static function text(before:String, edits:Array<CodeEdit>):String {
		var result = new StringBuf(), at = 0;
		for (edit in edits) {
			result.add(before.substring(at, edit.from));
			result.add(edit.text);
			at = edit.to;
		}
		result.add(before.substr(at));
		return result.toString();
	}
}
