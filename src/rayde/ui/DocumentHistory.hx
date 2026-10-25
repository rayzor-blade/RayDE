package rayde.ui;

import ashui.components.code.CodeEditorState;
import ashui.components.code.CodeHistory;
import ashui.components.code.CodeHistory.CodeSelection;
import ashui.components.code.CodeHistory.CodePatch;

/** Persistence adapter for the pinned editor's data-only history; captures no view or reactive owner. */
@:access(ashui.components.code.CodeHistory)
@:access(ashui.components.code.CodeEditorState)
class DocumentHistory {
	public static function canUndo(state:CodeEditorState, redo = false):Bool
		return state.onUndo != null || (redo ? state.history.redoStack : state.history.undoStack).length > 0;

	/** Applies a language-server edit to an unmounted document with its undo history intact. */
	public static function edit(state:CodeEditorState, next:String, parts:Array<CodePatch>):Void {
		if (state.mounted)
			throw "Use the mounted editor to edit this document";
		var before:CodeSelection = {caret: state.caret, anchor: state.anchor};
		function moved(offset:Int):Int {
			var shift = 0;
			for (part in parts) {
				if (offset <= part.from)
					break;
				if (offset < part.from + part.removed.length)
					return part.from + shift + part.inserted.length;
				shift += part.inserted.length - part.removed.length;
			}
			return offset + shift;
		}
		var after:CodeSelection = {caret: moved(state.caret), anchor: moved(state.anchor)};
		var old = state.value.get();
		if (state.onTransaction != null)
			state.onTransaction({
				before: old,
				after: next,
				parts: parts,
				selection: before,
				next: after
			});
		if (state.onUndo == null)
			state.history.recordParts(parts, before, after);
		state.knownValue = next;
		state.caret = after.caret;
		state.anchor = after.anchor;
		state.value.set(next);
	}

	public static function snapshot(state:CodeEditorState):Dynamic {
		var history = state.history;
		return {version: 1, undo: history.undoStack.copy(), redo: history.redoStack.copy()};
	}

	public static function restore(state:CodeEditorState, data:Dynamic):Void {
		if (data == null)
			return;
		try {
			if (data.version != 1 || !Std.isOfType(data.undo, Array) || !Std.isOfType(data.redo, Array))
				return;
			var bytes = 0, undo:Array<Dynamic> = data.undo, redo:Array<Dynamic> = data.redo;
			if (undo.length + redo.length > 100)
				return;
			for (edit in undo.concat(redo)) {
				if (edit.parts == null || edit.before == null || edit.after == null)
					return;
				for (selection in [edit.before, edit.after])
					if (!Std.isOfType(selection.caret, Int)
						|| !Std.isOfType(selection.anchor, Int)
						|| selection.caret < 0
						|| selection.anchor < 0)
						return;
				var parts:Array<Dynamic> = edit.parts, size = 64;
				for (part in parts) {
					if (!Std.isOfType(part.from, Int) || part.from < 0 || !Std.isOfType(part.removed, String) || !Std.isOfType(part.inserted, String))
						return;
					size += (part.removed.length + part.inserted.length) * 2 + 16;
				}
				edit.bytes = size;
				bytes += size;
			}
			if (bytes > state.history.limit)
				return;
			// Validate both stacks against the recovered text before adopting them.
			for (direction in [false, true]) {
				var probe = new CodeHistory();
				for (edit in undo)
					probe.undoStack.push(cast edit);
				for (edit in redo)
					probe.redoStack.push(cast edit);
				probe.bytes = bytes;
				var text = state.value.get(),
					count = direction ? redo.length : undo.length;
				for (_ in 0...count) {
					var next = probe.apply(text, direction);
					if (next == null)
						return;
					text = next.text;
				}
			}
			state.history.clear();
			for (edit in undo)
				state.history.undoStack.push(cast edit);
			for (edit in redo)
				state.history.redoStack.push(cast edit);
			state.history.bytes = bytes;
		} catch (_:Dynamic) {}
	}
}
