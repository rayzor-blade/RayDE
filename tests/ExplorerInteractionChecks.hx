import ashui.core.render.Offscreen;
import ashui.css.Css;
import ashui.input.Pointer;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;
import rayde.workspace.Fs;

@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.ExplorerPart)
@:access(rayde.ui.workbench.DocumentsPart)
@:access(rayde.ui.workbench.ProjectPart)
class ExplorerInteractionChecks {
 static function check(ok:Bool, why:String):Void { if (!ok) throw why; }
 static function main():Void {
  var previous = Fs.current, home = Sys.getEnv("HOME"), ext = Sys.getEnv("RAYDE_EXTENSIONS");
  try for (dark in [false,true]) run(dark) catch (error:Dynamic) { Fs.current=previous; Sys.putEnv("HOME",home); Sys.putEnv("RAYDE_EXTENSIONS",ext); throw error; }
  Fs.current=previous; Sys.putEnv("HOME",home); Sys.putEnv("RAYDE_EXTENSIONS",ext);
  Sys.println("Explorer gestures: moves, dirty tabs/undo, hover expansion, cancellation, collisions, refusal and cleanup; repository picker: signed-out state and cancellation in both themes");
 }
 static function run(dark:Bool):Void {
  var memory = new rayde.workspace.MemoryWorkspace(); Fs.current=memory;
  for (dir in ["/home/check", "/work/from/nested", "/work/to", "/work/empty-extensions"]) Fs.createDirectory(dir);
  Sys.putEnv("HOME","/home/check"); Sys.putEnv("RAYDE_EXTENSIONS","/work/empty-extensions");
  Fs.saveContent("/work/from/one.txt","one\n"); Fs.saveContent("/work/from/nested/deep.txt","deep");
  Fs.saveContent("/work/from/duplicate.txt","source"); Fs.saveContent("/work/to/duplicate.txt","target");
  Fs.saveContent("/work/build.hxml","-cp from\n"); Fs.saveContent("/work/rayzor.toml","[project]\nname = 'sample'\n");
  for (i in 0...100) Fs.saveContent('/work/other$i.hxml',"-cp from\n");
  ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),dark ? Dark : Light); rayde.ui.Style.use();
  var compiler = new CompilerServer(), tree = new LayoutTree(), stop:Void->Void = null, picked = "";
  var bench = Owner.root(tree,cleanup -> {stop=cleanup; return new Workbench({display:new Display(compiler,"/work",[]),name:"Workspace",onWorkspace:path -> picked=path});});
  function settle(frames=4):Void for (_ in 0...frames) {Offscreen.advance(.025); Css.update(); tree.flush(); tree.computeLayout(bench.node,1100,760);}
  function count(selector:String):Int return Css.query(tree,bench.node.id,selector).length;
  function box(selector:String):ashui.layout.Bounds {var nodes=Css.query(tree,bench.node.id,selector); check(nodes.length==1,'Missing $selector'); return tree.getScrolledBounds(new Node(nodes[0]));}
  function row(path:String):String return '.ui-tree-item[data-path="$path"] > .ui-tree-row';
  function click(selector:String):Void {var b=box(selector); Pointer.move(tree,b.x+b.width/2,b.y+b.height/2); Pointer.press(tree);Pointer.release(tree);settle();}
  function until(done:Void->Bool):Void {var end=haxe.Timer.stamp()+10; while(haxe.Timer.stamp()<end) {settle();if(done())return;Sys.sleep(.005);}check(done(),"UI did not settle");}
  function start(path:String, into:String):Void {var a=box(row(path)), b=box(row(into)); Pointer.move(tree,a.x+a.width/2,a.y+a.height/2); Pointer.press(tree); Pointer.move(tree,b.x+b.width/2,b.y+b.height/2);settle();}
  try {
   bench.explorerPart.folderState("/work/from",true).set(true); bench.explorerPart.folderState("/work/from/nested",true).set(true);
   bench.openProject();until(() -> count(row("/work/from/one.txt"))==1);
   bench.openFile("/work/from/one.txt");settle(); var editor=bench.editorFor("/work/from/one.txt"), state=editor.state;
   editor.applyEdits([{from:0,to:0,text:"unsaved "}]); bench.documentsPart.edited("/work/from/one.txt");settle();var value=editor.value.get();
   var hooks=Pointer.hooks.length;
   start("/work/from/one.txt","/work/to");check(count(".rayde-explorer-drag")==1 && count("[data-drop-target]")==1,"Missing drag feedback");
   settle(30);check(bench.explorerPart.folderState("/work/to").get(),"Hover did not expand folder");
   Pointer.release(tree);until(() -> !bench.explorerPart.movingFile);
   check(Fs.exists("/work/to/one.txt") && !Fs.exists("/work/from/one.txt"),"Drop did not move file");
   check(bench.active.get()=="/work/to/one.txt" && bench.documentsPart.buffer("/work/to/one.txt").get()==value && bench.dirty.get().indexOf("/work/to/one.txt")>=0,"Moved tab lost unsaved text");
   check(bench.editorFor("/work/to/one.txt").state==state,"Move replaced document history");
   bench.editorFor("/work/to/one.txt").undo();settle();check(bench.documentsPart.buffer("/work/to/one.txt").get()=="one\n","Undo did not survive move");
   start("/work/from/duplicate.txt","/work/to");Pointer.release(tree);until(() -> !bench.explorerPart.movingFile);
   check(Fs.getContent("/work/from/duplicate.txt")=="source" && Fs.getContent("/work/to/duplicate.txt")=="target","Collision overwrote a file");
   start("/work/from/nested/deep.txt","/work/to");ashui.input.Keyboard.input(tree,window.KeyEvent.Input(Unidentified(Unidentified),Named(Escape),None,Standard,Pressed,false,Unavailable));Pointer.release(tree);settle();
   check(Fs.exists("/work/from/nested/deep.txt") && count(".rayde-explorer-drag")==0 && Pointer.hooks.length==hooks,"Escape failed to clean up drag");
   start("/work/from","/work/from/nested");Pointer.release(tree);settle();check(Fs.exists("/work/from/nested/deep.txt"),"Folder was moved into itself");
   bench.contributions.refuses((path,_) -> path=="/work/from/nested/deep.txt" ? "Shared document is busy" : null);
   start("/work/from/nested/deep.txt","/work/to");Pointer.release(tree);settle();check(Fs.exists("/work/from/nested/deep.txt"),"Move ignored provider refusal");
   var area=box("#rayde-explorer-scroll"), origin=box(row("/work/from/duplicate.txt"));
   Pointer.move(tree,origin.x+origin.width/2,origin.y+origin.height/2);Pointer.press(tree);Pointer.move(tree,area.x+area.width/2,area.y+area.height-3);settle(25);
   var scroll=ashui.input.Scroll.at(Css.query(tree,bench.node.id,"#rayde-explorer-scroll")[0],tree);
   check(scroll.y.get()>0 && count(".rayde-explorer-drag")==1,"Drag did not scroll through virtual rows");
   Pointer.leave(tree);Pointer.release(tree);settle();check(count(".rayde-explorer-drag")==0 && Pointer.hooks.length==hooks,"Leaving the window retained the drag");
   scroll.jumpTo(0,0);settle();
   #if rayde_page
   bench.projectPart.pickProject("project");until(() -> count("#rayde-repository-signin")==1);
   check(count("#rayde-workspace-browser")==0,"Open Project used a filesystem picker in a browser");
   click("#rayde-repository-cancel");check(!bench.projectPart.pickingProject,"Cancelled repository picker remained locked");
   bench.projectPart.pickProject("folder");until(() -> count("#rayde-repository-signin")==1);click("#rayde-repository-cancel");check(!bench.projectPart.pickingProject,"Cancelled folder picker remained locked");
   #end
   check(Pointer.hooks.length==hooks,"Idle Explorer kept drag hooks");
  } catch(error:Dynamic) {stop();tree.dispose();compiler.stop();throw error;}
  stop();tree.dispose();compiler.stop();
 }
}
