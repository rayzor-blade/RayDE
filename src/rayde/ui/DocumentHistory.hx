package rayde.ui;

import ashui.components.code.CodeEditorState;
import ashui.components.code.CodeHistory;

/** Persistence adapter for the pinned editor's data-only history; captures no view or reactive owner. */
@:access(ashui.components.code.CodeHistory)
@:access(ashui.components.code.CodeEditorState)
class DocumentHistory {
	public static function snapshot(state:CodeEditorState):Dynamic {
		var history = state.history;
		return {version:1, undo:history.undoStack.copy(), redo:history.redoStack.copy()};
	}

	public static function restore(state:CodeEditorState, data:Dynamic):Void {
		if (data == null) return;
		try {
			if (data.version != 1 || !Std.isOfType(data.undo, Array) || !Std.isOfType(data.redo, Array)) return;
			var bytes = 0, undo:Array<Dynamic> = data.undo, redo:Array<Dynamic> = data.redo;
			if (undo.length + redo.length > 100) return;
			for (edit in undo.concat(redo)) {
				if (edit.parts == null || edit.before == null || edit.after == null) return;
				for (selection in [edit.before, edit.after]) if (!Std.isOfType(selection.caret, Int) || !Std.isOfType(selection.anchor, Int) || selection.caret < 0 || selection.anchor < 0) return;
				var parts:Array<Dynamic> = edit.parts, size = 64;
				for (part in parts) {
					if (!Std.isOfType(part.from, Int) || part.from < 0 || !Std.isOfType(part.removed, String) || !Std.isOfType(part.inserted, String)) return;
					size += (part.removed.length + part.inserted.length) * 2 + 16;
				}
				edit.bytes = size; bytes += size;
			}
			if (bytes > state.history.limit) return;
			// Validate both stacks against the recovered text before adopting them.
			for (direction in [false, true]) {
				var probe = new CodeHistory();
				for (edit in undo) probe.undoStack.push(cast edit);
				for (edit in redo) probe.redoStack.push(cast edit);
				probe.bytes = bytes;
				var text = state.value.get(), count = direction ? redo.length : undo.length;
				for (_ in 0...count) { var next = probe.apply(text, direction); if (next == null) return; text = next.text; }
			}
			state.history.clear();
			for (edit in undo) state.history.undoStack.push(cast edit);
			for (edit in redo) state.history.redoStack.push(cast edit);
			state.history.bytes = bytes;
		} catch (_:Dynamic) {}
	}
}
