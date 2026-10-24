package rayde.jam;

import ashui.components.CodeEditor;
import ashui.reactive.Owner;
import ashui.reactive.Watch;
import rayde.jam.JamSession.JamPosition;
import rayde.jam.JamSession.JamViewport;

/** A mounted editor's ephemeral presence and follow view; the room owns only data. */
@:access(ashui.components.CodeEditor)
class JamEditor {
	static inline var INSET = CodeEditor.PAD;
	final editor:CodeEditor;
	final file:String;
	final session:Void->Null<JamSession>;
	var timer:Null<ashui.animation.AnimationScheduler.Timer>;
	var desired:Null<JamViewport>;
	var last:Null<JamPosition>;
	var gone = false;

	public function new(editor:CodeEditor,file:String,session:Void->Null<JamSession>) {
		this.editor=editor; this.file=file; this.session=session;
		ashui.input.Interaction.of(editor.node);
		var inputs=ashui.input.Interaction.inTree(editor.tree);
		for (input in inputs) if (input.node.id == editor.node.id || editor.tree.ancestors(input.node.id).indexOf(editor.node.id) >= 0) {
			input.onPointerDown(_ -> localNavigation()).onWheel(_ -> localNavigation())
				.onKeyDown(_ -> localNavigation()).onTextInput(_ -> localNavigation()).onComposition(_ -> localNavigation());
		}
		new Watch(() -> {
			var current=session();
			editor.editing.caret.get(); editor.editing.anchor.get(); editor.editing.composing.get(); editor.scroll.x.get(); editor.scroll.y.get();
			if (current != null) { current.status.get(); current.following.get(); }
			0;
		}, _ -> {
			var current=current();
			if (current == null || editor.editing.composing.get() != "" || current.following.get() != "") return;
			remember(current);
			if (timer != null) return;
			timer=ashui.animation.AnimationScheduler.main.after(.04,() -> {
				timer=null;
				var latest=this.current();
				if (!gone && latest != null && editor.editing.composing.get() == "") {
					remember(latest); latest.moved(editor.editing.caret.get(),editor.editing.anchor.get());
				}
			});
		},(_,_) -> false);
		new Watch(() -> {
			var current=current();
			if (current == null) return null;
			var id=current.following.get();
			editor.editing.composing.get();
			return id == "" ? null : current.positionOf(id);
		}, position -> follow(position),(_,_) -> false);
		var layout= (tree:ashui.layout.LayoutTree) -> {
			if (gone || tree != editor.tree || desired == null || current() == null || current().following.get() == "") return false;
			var view=desired, max=editor.scroll.limits();
			var row=editor.metrics.stopAt(view.top).line;
			var x=Math.min(max.x,Math.max(0,view.x*editor.metrics.characterWidth));
			var y=Math.min(max.y,Math.max(0,INSET+(row+view.offset)*editor.metrics.lineHeight));
			if (Math.abs(editor.scroll.x.get()-x)<.1 && Math.abs(editor.scroll.y.get()-y)<.1) return false;
			editor.scroll.jumpTo(x,y); return true;
		};
		ashui.layout.LayoutTree.layoutHooks.push(layout);
		Owner.onCleanup(() -> {
			gone=true; if (timer != null) timer.cancel(); timer=null; desired=null;
			ashui.layout.LayoutTree.layoutHooks.remove(layout);
		});
	}
	function current():Null<JamSession> {
		var current=session(); return current != null && current.file == file ? current : null;
	}
	function remember(current:JamSession):Void {
		var h=Math.max(1,editor.metrics.lineHeight), y=(editor.scroll.y.get()-INSET)/h;
		var row=Std.int(Math.max(0,Math.floor(y)));
		var line=editor.document.lines[editor.metrics.sourceLine(row)];
		current.remember(editor.editing.caret.get(),editor.editing.anchor.get(),{top:line.start,offset:y-row,x:Math.min(1000000,editor.scroll.x.get()/Math.max(1,editor.metrics.characterWidth))});
	}
	function localNavigation():Void {
		var current=current(); if (current != null) current.stopFollowing(); desired=null; last=null;
	}
	static function sameView(a:Null<JamViewport>,b:Null<JamViewport>):Bool
		return a == null ? b == null : b != null && a.top == b.top && a.offset == b.offset && a.x == b.x;
	function follow(position:Null<JamPosition>):Void {
		if (position == null) { desired=null; last=null; return; }
		if (editor.editing.composing.get() != "") return;
		if (last != null && last.id == position.id && last.caret == position.caret && last.anchor == position.anchor && sameView(last.view,position.view)) return;
		last=position;
		if (position.view != null) editor.document.unfoldAt(position.view.top);
		editor.select(position.anchor,position.caret);
		desired=position.view;
		if (desired == null) editor.revealSelection();
	}
}
