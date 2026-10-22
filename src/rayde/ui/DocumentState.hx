package rayde.ui;

import ashui.components.code.CodeDocument.CodeLine;
import ashui.components.code.CodeEditorState;
import ashui.reactive.Signal;

/** Persistent editor data whose inactive caches do not pin the lexer's temporary allocation blocks. */
class DocumentState extends CodeEditorState {
	var packedGeneration = -1;

	public function new(value:Signal<String>) super(value);

	/** Copies completed caches together, preserving tokens and navigation without re-highlighting. */
	public function compact():Void @:privateAccess {
		var cache = document;
		if (mounted || cache == null || cache.generation == packedGeneration) return;
		var lines:Array<CodeLine> = [];
		for (old in cache.lines) {
			var line = new CodeLine(old.text.substr(0));
			line.start = old.start;
			line.packed = old.packed == null ? null : old.packed.copy();
			line.styles = old.styles == null ? null : old.styles.copy();
			line.tokenRevision = old.tokenRevision;
			line.incoming = old.incoming == null ? null : old.incoming.substr(0);
			line.outgoing = old.outgoing.substr(0);
			line.foldEnd = old.foldEnd;
			line.folded = old.folded;
			line.generation = old.generation;
			lines.push(line);
		}
		cache.lines = lines;
		cache.visible = cache.visible.copy();
		cache.rows = cache.rows.copy();
		var brackets = [for (from => to in cache.brackets) {from:from, to:to}];
		cache.brackets.clear();
		for (pair in brackets) cache.brackets.set(pair.from, pair.to);
		packedGeneration = cache.generation;
	}
}
