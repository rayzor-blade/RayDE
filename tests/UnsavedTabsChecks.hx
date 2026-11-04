import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.input.Pointer;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.DocumentsPart)
@:access(rayde.ui.workbench.EditorPart)
@:access(rayde.ui.workbench.RunPart)
class UnsavedTabsChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	static function main():Void {
		LocalHistoryChecks.run();
		var home = Sys.getEnv("HOME"), extensions = Sys.getEnv("RAYDE_EXTENSIONS");
		try for (dark in [false,true]) run(dark) catch (error:Dynamic) {
			Sys.putEnv("HOME",home); Sys.putEnv("RAYDE_EXTENSIONS",extensions); throw error;
		}
		Sys.putEnv("HOME",home); Sys.putEnv("RAYDE_EXTENSIONS",extensions);
		Sys.println("Unsaved tabs: content savepoints, undo/redo, recovery, scoped Save, Cancel, Discard, bulk split preservation and failed saves passed in both themes");
	}
	static function run(dark:Bool):Void {
		var root = Sys.getCwd()+"bin/unsaved-tabs-"+Std.random(0x3fffffff);
		for (folder in ["home","workspace","extensions"]) sys.FileSystem.createDirectory(root+"/"+folder);
		Sys.putEnv("HOME",root+"/home"); Sys.putEnv("RAYDE_EXTENSIONS",root+"/extensions");
		var a = root+"/workspace/A.txt", b = root+"/workspace/B.txt";
		for (file in [a,b]) sys.io.File.saveContent(file,"saved original\n");
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),dark ? Dark : Light);
		rayde.ui.Style.use();
		var tree = new LayoutTree(), compiler = new CompilerServer(), dispose:Void->Void = null;
		var wb = Owner.root(tree,cleanup -> { dispose=cleanup; return new Workbench({display:new Display(compiler,root+"/workspace",[]),name:"Unsaved tabs"}); });
		function settle():Void for (_ in 0...5) {
			Offscreen.advance(.025); Css.setViewport(1100,760); Css.update(); tree.flush(); tree.computeLayout(wb.node,1100,760);
		}
		function click(selector:String):Void {
			var found=Css.query(tree,tree.root.id,selector); check(found.length==1,"Missing "+selector);
			var box=tree.getScrolledBounds(new Node(found[0]));
			Pointer.move(tree,box.x+box.width/2,box.y+box.height/2); Pointer.press(tree); Pointer.release(tree); settle();
		}
		function edit(file:String,text:String):Void {
			wb.openFile(file); settle(); var editor=wb.editorFor(file);
			editor.applyEdits([{from:0,to:editor.value.get().length,text:text}]); settle();
		}
		try {
			wb.openProject(); wb.openFile(a); settle();
			var editor=wb.editorFor(a);
			edit(a,"first edit\n"); check(wb.dirty.get().indexOf(a)>=0,"Typing did not mark dirty");
			editor.undo(); settle(); check(wb.dirty.get().indexOf(a)<0,"Undo to original saved text stayed dirty");
			editor.redo(); settle(); check(wb.dirty.get().indexOf(a)>=0,"Redo away from saved text stayed clean");
			wb.runPart.saveFile(a); settle(); check(wb.dirty.get().length==0 && sys.io.File.getContent(a)=="first edit\n","Save did not move the savepoint");
			editor.undo(); settle(); check(wb.dirty.get().indexOf(a)>=0,"Undo before the new savepoint stayed clean");
			editor.redo(); settle(); check(wb.dirty.get().length==0,"Redo to new savepoint stayed dirty");
			edit(a,"discarded but recoverable\n");
			wb.openFile(b); settle(); wb.editorPart.splitEditor("horizontal"); settle();
			wb.openFile(a); settle(); editor=wb.editorFor(a); editor.select(1,8); settle();
			var front=wb.active.get(), order=wb.open.get().join("|"), groups=wb.editorPart.groups.all().length;
			wb.closeAll(); settle();
			check(wb.prompt.get()!=null && wb.open.get().join("|")==order && wb.active.get()==front && wb.editorPart.groups.all().length==groups,"Close All changed tabs or split layout before confirmation");
			Snapshot.capture("unsaved-close-"+(dark ? "dark" : "light"),tree,wb.node,1100,760);
			click("#rayde-prompt-cancel");
			check(wb.prompt.get()==null && wb.open.get().join("|")==order && wb.active.get()==front && editor.editing.selection()=="iscarde","Cancel lost state: prompt="+(wb.prompt.get()!=null)+" order="+wb.open.get().join("|")+" expected="+order+" active="+wb.active.get()+" expected="+front+" selection="+editor.editing.selection()+" groups="+wb.editorPart.groups.all().length);
			check(sys.io.File.getContent(a)=="first edit\n","Unsaved editing wrote the file");
			wb.closeFile(a); settle(); click("#rayde-prompt-discard");
			check(wb.open.get().indexOf(a)<0 && wb.dirty.get().indexOf(a)<0 && sys.io.File.getContent(a)=="first edit\n","Discard wrote the saved file or left the tab open");
			wb.openFile(a); settle(); check(wb.documentsPart.buffer(a).get()=="first edit\n","Discard resurrected abandoned changes on reopening");
			var revisions=wb.documentsPart.localHistory.entries(a,"first edit\n");
			check(Lambda.exists(revisions,entry -> wb.documentsPart.localHistory.revision(a,"first edit\n",entry.id)=="discarded but recoverable\n"),"Discard lost Timeline recovery");
			edit(a,"save only A\n"); edit(b,"B must stay unsaved\n");
			wb.closeFile(a); settle(); click("#rayde-prompt-accept");
			check(wb.open.get().indexOf(a)<0 && wb.open.get().indexOf(b)>=0 && wb.dirty.get().indexOf(b)>=0 && sys.io.File.getContent(a)=="save only A\n" && sys.io.File.getContent(b)=="saved original\n","Scoped Save closed or wrote the wrong files");
			wb.closeFile(b); settle(); sys.FileSystem.deleteFile(b); sys.FileSystem.createDirectory(b); click("#rayde-prompt-accept");
			check(wb.open.get().indexOf(b)>=0 && wb.dirty.get().indexOf(b)>=0,"Failed Save closed the tab");
			sys.FileSystem.deleteDirectory(b); sys.io.File.saveContent(b,"saved original\n");
			// A save completing behind typing retains the newer buffer and advances its baseline.
			wb.runPart.fileSaved(b,"completed save\n");
			check(wb.dirty.get().indexOf(b)>=0,"Late Save cleared newer unsaved typing");
			edit(b,"completed save\n"); check(wb.dirty.get().indexOf(b)<0,"Returning to a completed savepoint stayed dirty");
			edit(b,"bulk B\n"); edit(a,"bulk A\n");
			wb.closeAll(); settle(); check(wb.prompt.get()!=null && wb.prompt.get().description.indexOf("2 files")>=0,"Bulk close did not use one prompt");
			click("#rayde-prompt-discard"); check(wb.open.get().length==0 && wb.dirty.get().length==0,"Bulk discard left tabs or dirty buffers");
		} catch (error:Dynamic) { dispose(); compiler.stop(); throw error; }
		dispose(); compiler.stop();
	}
}
