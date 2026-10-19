package rayde.ui;

import ashui.components.CodeEditor;
import ashui.components.code.CodeCompletions.CodeCompletion;
import ashui.components.code.CodeHints.CodeHint;
import rayde.lang.CallSite;
import rayde.lang.Display;
import rayde.lang.Display.CompletionItem;
import rayde.lang.Display.SignatureHelp;
import rayde.lang.Display.TextPosition;

/**
 * The completion list and signature help of a Haxe editor, answered by the compilation server. The list opens when a
 * member access or a new word is typed, or on request; the editor narrows it as the word grows. Signature help opens at a
 * call's `(` or `,` and stays while the caret is inside the call: the editor closes a hint on every edit, so it is shown
 * again from the text, with the parameter the caret is in emphasised, and the compiler is asked only for a new call.
 */
class CodeAssist {
	final display:Display;

	/** The call each file's signature help is showing: where its `(` is, and what the compiler said for it. */
	final calls = new Map<String, {open:Int, help:SignatureHelp}>();

	public function new(display:Display)
		this.display = display;

	/** Called after an edit of `file`, whose text is now `text`. */
	public function typed(file:String, editor:CodeEditor, text:String):Void {
		var caret = editor.editing.caret.get();
		if (caret <= 0 || caret > text.length)
			return;
		var c = text.charAt(caret - 1);
		if (!editor.completionsOpen() && (c == "." || (word(c) && !digit(c) && (caret < 2 || !word(text.charAt(caret - 2))))))
			complete(file, editor, text, true);
		if (c == "(" || c == ",")
			signature(file, editor, text, true);
	}

	/** How long after a change signature help is shown again, in seconds: the editor closes a hint when its text or view changes, and does so after the change handlers have run. */
	static inline var SETTLE = .03;

	final waiting = new Map<String, Bool>();

	/** Called when the text or the caret of `file` changed: inside a call, the signatures are shown again once the editor has closed the hint. */
	public function moved(file:String, editor:CodeEditor):Void {
		if (!calls.exists(file) || waiting.exists(file))
			return;
		waiting.set(file, true);
		ashui.animation.AnimationScheduler.main.after(SETTLE, () -> {
			waiting.remove(file);
			if (calls.exists(file))
				follow(file, editor, editor.value.get());
		});
	}

	/** Opens the list at the caret: what the compiler offers there, narrowed by the word before the caret. */
	public function complete(file:String, editor:CodeEditor, text:String, auto = false):Void {
		var caret = editor.editing.caret.get();
		var found = try display.completion(file, Display.byteOffset(text, caret), text, auto) catch (_:Dynamic) null;
		if (found == null || found.items.length == 0) {
			editor.hideCompletions();
			return;
		}
		var from = found.replace == null ? caret - found.filter.length : offsetOf(text, found.replace.start);
		editor.showCompletions([for (i in found.items) item(i)], from);
	}

	/** Asks the compiler for the signatures of the call the caret is in, and shows them. */
	public function signature(file:String, editor:CodeEditor, text:String, auto = false):Void {
		var caret = editor.editing.caret.get(), open = CallSite.openParen(text, caret);
		if (open < 0) {
			stop(file, editor);
			return;
		}
		var help = try display.signatureHelp(file, Display.byteOffset(text, caret), text, auto) catch (_:Dynamic) null;
		if (help == null || help.signatures.length == 0) {
			stop(file, editor);
			return;
		}
		calls.set(file, {open: open, help: help});
		show(editor, text, caret, open, help);
	}

	/** Takes signature help away, as when the call ends or the file closes. */
	public function stop(file:String, editor:Null<CodeEditor>):Void {
		calls.remove(file);
		if (editor != null)
			editor.hideHint();
	}

	/** Inside a call, edits show the same signatures again with the argument the caret is in emphasised; a different call is asked for. */
	function follow(file:String, editor:CodeEditor, text:String):Void {
		var shown = calls.get(file), caret = editor.editing.caret.get(), open = CallSite.openParen(text, caret);
		if (open < 0)
			stop(file, editor);
		else if (open == shown.open)
			show(editor, text, caret, open, shown.help);
		else
			signature(file, editor, text, true);
	}

	function show(editor:CodeEditor, text:String, caret:Int, open:Int, help:SignatureHelp):Void {
		var s = help.signatures[Std.int(Math.max(0, Math.min(help.active, help.signatures.length - 1)))];
		var span = CallSite.emphasis(s.label, CallSite.parameterIndex(text, open, caret));
		// The popover sits under a character: the call's `(`, or the one before the caret when that is out of view. The editor has no rectangle for a line's end.
		var from = editor.rectAt(open) != null ? open : Std.int(Math.max(0, caret - 1));
		editor.showHint({from: from, to: from + 1, signature: s.label, language: "haxe", docs: s.documentation, emphasis: span}, true);
	}

	static function item(i:CompletionItem):CodeCompletion
		return {label: i.label, detail: i.detail == "" ? null : i.detail, docs: i.documentation, kind: kind(i)};

	/** The compiler's kind of an item as the list names its icon letter. */
	static function kind(i:CompletionItem):String
		return switch i.kind {
			case "Local": "variable";
			case "ClassField" | "EnumAbstractField": i.detail.indexOf("->") >= 0 || i.detail.charAt(0) == "(" ? "method" : "field";
			case "EnumField": "field";
			case "Type": "class";
			case "Package" | "Module": "module";
			case "Keyword" | "Literal": "keyword";
			case _: "field";
		};

	static function word(c:String):Bool
		return c == "_" || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || digit(c);

	static function digit(c:String):Bool
		return c >= "0" && c <= "9";

	/** The offset of a line and character position in `text`. */
	static function offsetOf(text:String, p:TextPosition):Int {
		var at = 0;
		for (_ in 0...p.line) {
			var next = text.indexOf("\n", at);
			if (next < 0)
				return text.length;
			at = next + 1;
		}
		return Std.int(Math.min(text.length, at + p.character));
	}
}
