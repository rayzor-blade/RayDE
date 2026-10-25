package rayde.ui;

import ashui.components.CodeEditor;
import rayde.lang.LspProtocol;
import rayde.lang.WorkspaceEdits;

@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.DocumentsPart)
@:access(rayde.ui.workbench.LanguagesPart)
class EditorCommands {
	static final capabilities = [
		"definition" => "definitionProvider",
		"typedefinition" => "typeDefinitionProvider",
		"implementation" => "implementationProvider",
		"references" => "referencesProvider",
		"renamesymbol" => "renameProvider",
		"formatdocument" => "documentFormattingProvider"
	];

	public static function available(wb:Workbench, file:String, command:String):Bool {
		var editor = wb.editorOf(file);
		if (editor == null || ((command == "renamesymbol" || command == "formatdocument") && editor.editing.readOnly))
			return false;
		var client = wb.languagesPart.languageServers.client(file);
		return client == null ? command == "definition"
			&& StringTools.endsWith(file.toLowerCase(), ".hx") : client.supports(capabilities.get(command));
	}

	public static function active(wb:Workbench, command:String):Void {
		var file = wb.active.get(), editor = wb.editorOf(file);
		if (editor != null)
			run(wb, file, editor, command);
	}

	public static function run(wb:Workbench, file:String, editor:CodeEditor, command:String, ?position:Int):Void {
		var caret = editor.editing.caret.get(), offset = position ?? caret;
		if (!available(wb, file, command)) {
			wb.say("The language server does not offer this action here.");
			return;
		}
		if (command == "definition") {
			wb.definitionAt(file, offset);
			return;
		}
		var languages = wb.languagesPart.languageServers,
			client = languages.client(file);
		var text = editor.value.get();
		function current():Bool
			return !wb.gone && wb.active.get() == file && wb.editorOf(file) == editor && editor.value.get() == text;
		function request(name:Null<String>):Void {
			if (!current()) {
				wb.say("The document changed; invoke the action again.");
				return;
			}
			languages.sync(file, text);
			var params:Dynamic = LspProtocol.at(file, text, offset),
				method = switch command {
					case "typedefinition": "typeDefinition";
					case "implementation": "implementation";
					case "references": "references";
					case "renamesymbol": "rename";
					case _: "formatting";
				};
			if (command == "references")
				params.context = {includeDeclaration: true};
			if (command == "renamesymbol")
				params.newName = name;
			if (command == "formatdocument")
				params = {textDocument: {uri: LspProtocol.uri(file)}, options: {tabSize: 4, insertSpaces: false}};
			var snapshots = new Map<String, String>();
			if (command == "renamesymbol" || command == "formatdocument")
				for (path => buffer in wb.documentsPart.buffers)
					snapshots.set(path, buffer.get());
			client.request("textDocument/" + method, params, result -> {
				if (!current())
					return;
				if (command == "renamesymbol" || command == "formatdocument") {
					if (editor.editing.readOnly)
						return;
					try {
						var edit = command == "formatdocument" ? {changes: makeChanges(file, result)} : result;
						apply(wb, file, WorkspaceEdits.documents(edit), snapshots);
					} catch (error:Dynamic)
						wb.say(Std.string(error));
				} else {
					if (editor.editing.caret.get() != caret)
						return;
					var places = LspProtocol.locations(result);
					if (places.length == 0) {
						wb.say("No locations found");
						return;
					}
					if (places.length == 1) {
						var p = places[0];
						wb.goTo(p.file, p.range.start.line, p.range.start.character);
					} else
						wb.openPicker(command == "references" ? "References" : "Go to", [
							for (index => p in places)
								{id: "location-" + index,
									label: relative(wb, p.file)
									+ ":"
									+ (p.range.start.line + 1)
									+ ":"
									+ (p.range.start.character + 1),
									icon: FileIcons.of(p.file),
									run: () -> wb.goTo(p.file, p.range.start.line, p.range.start.character)
								}
						]);
				}
			}, file + "#editor-command");
		}
		if (command == "renamesymbol") {
			var from = offset, to = offset;
			function word(at:Int):Bool {
				var c = text.charCodeAt(at);
				return c != null && (c >= 128 || c >= 48 && c <= 57 || c >= 65 && c <= 90 || c >= 97 && c <= 122 || c == 95 || c == 36);
			}
			while (from > 0 && word(from - 1))
				from--;
			while (to < text.length && word(to))
				to++;
			wb.prompt.set({
				title: "Rename Symbol",
				description: "Choose the symbol's new name.",
				action: "Rename",
				hasInput: true,
				value: text.substring(from, to),
				check: value -> StringTools.trim(value) == ""
					|| value.indexOf("\n") >= 0
					|| value.indexOf("\r") >= 0 ? "Enter a symbol name." : null,
				accept: request
			});
		} else
			request(null);
	}

	static function makeChanges(file:String, edits:Dynamic):Dynamic {
		var changes:Dynamic = {};
		Reflect.setField(changes, LspProtocol.uri(file), edits == null ? [] : edits);
		return changes;
	}

	static function relative(wb:Workbench, file:String):String {
		var root = haxe.io.Path.addTrailingSlash(wb.props.display.cwd);
		return StringTools.startsWith(file, root) ? file.substr(root.length) : haxe.io.Path.withoutDirectory(file);
	}

	static function apply(wb:Workbench, origin:String, documents:Array<DocumentEdits>, snapshots:Map<String, String>):Void {
		var plans = [], root = haxe.io.Path.addTrailingSlash(haxe.io.Path.normalize(sys.FileSystem.fullPath(wb.props.display.cwd)));
		for (document in documents) {
			var file = document.file;
			if (!sys.FileSystem.exists(file) || sys.FileSystem.isDirectory(file))
				throw "An edit targets a missing file.";
			file = haxe.io.Path.normalize(sys.FileSystem.fullPath(file));
			if (!StringTools.startsWith(file, root))
				throw "An edit targets a file outside the workspace.";
			if (wb.contributions.readOnly(file))
				throw "An edit targets a read-only document.";
			var client = wb.languagesPart.languageServers.client(file);
			if (document.version != null && (client == null || client.version(file) != document.version))
				throw "A document changed; invoke the action again.";
			var text = wb.documentsPart.buffers.exists(file) ? wb.documentsPart.buffer(file).get() : sys.io.File.getContent(file);
			if (snapshots.exists(file) && snapshots.get(file) != text)
				throw "A document changed; invoke the action again.";
			var edits = WorkspaceEdits.edits(text, document.edits),
				next = WorkspaceEdits.text(text, edits);
			if (next != text)
				plans.push({
					file: file,
					text: text,
					next: next,
					edits: edits
				});
		}
		if (plans.length == 0) {
			wb.say("No edits were returned");
			return;
		}
		try
			for (plan in plans)
				if (wb.editorOf(plan.file) == null && wb.documentsPart.documentState(plan.file).value.get() != plan.text)
					throw "A document has recovered changes; invoke the action again."
		catch (error:Dynamic) {
			wb.documentsPart.releaseClosedDocuments();
			throw error;
		}
		for (plan in plans) {
			var editor = wb.editorOf(plan.file);
			if (editor != null)
				editor.applyEdits(plan.edits);
			else {
				var state = wb.documentsPart.documentState(plan.file);
				DocumentHistory.edit(state, plan.next, [
					for (edit in plan.edits) {from: edit.from, removed: plan.text.substring(edit.from, edit.to), inserted: edit.text}
				]);
				wb.documentsPart.edited(plan.file);
			}
		}
		for (plan in plans)
			wb.openFile(plan.file);
		wb.openFile(origin);
	}
}
