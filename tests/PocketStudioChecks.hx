import ashui.css.Css;
import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.theme.ThemeState;
import state.BoardStore;
import ui.BoardApp;

@:access(ui.BoardApp)
class PocketStudioChecks {
    static function check(value:Bool, message:String):Void if (!value) throw message;
    static function main():Void {
        var previous=Sys.getCwd(), scratch=previous+"bin/pocket-board-"+Std.random(0x3fffffff);
        sys.FileSystem.createDirectory(scratch+"/data");
        sys.io.File.copy(previous+"site/demo/data/tasks.json",scratch+"/data/tasks.json");
        Sys.putEnv("ASHUI_SNAPSHOT_DIR",previous+"bin/web/pocket-demo-shots");
        Sys.setCwd(scratch);
        ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),Dark);
        var tree=new LayoutTree(), store:BoardStore=null, stop:Void->Void=null;
        var view=Owner.root(tree,cleanup -> {stop=cleanup;store=new BoardStore();return new BoardApp({store:store});});
        function settle():Void for (_ in 0...4) {
            Offscreen.advance(1/60);Css.setViewport(1100,740);Css.update();tree.flush();tree.computeLayout(view.node,1100,740);
        }
        function click(selector:String):Void {
            var found=Css.query(tree,view.node.id,selector);check(found.length==1,"Missing demo control "+selector);
            var bounds=tree.getScrolledBounds(new ashui.layout.Node(found[0]));
            check(bounds.width>0&&bounds.height>0,"Hidden demo control "+selector);
            ashui.input.Pointer.move(tree,bounds.x+bounds.width/2,bounds.y+bounds.height/2);
            ashui.input.Pointer.press(tree);ashui.input.Pointer.release(tree);settle();
        }
        function bounds(selector:String) {
            var found=Css.query(tree,view.node.id,selector);check(found.length==1,"Missing demo node "+selector);
            return tree.getScrolledBounds(new ashui.layout.Node(found[0]));
        }
        function beginDrag(id:Int,lane:String):Void {
            var from=bounds("#pocket-task-"+id),to=bounds("#pocket-lane-"+lane.split(" ").join("-"));
            ashui.input.Pointer.move(tree,from.x+20,from.y+20);ashui.input.Pointer.press(tree);
            ashui.input.Pointer.move(tree,from.x+30,from.y+30);settle();
            check(Css.query(tree,view.node.id,".board-drag-preview").length==1,"Drag has no card preview");
            ashui.input.Pointer.move(tree,to.x+to.width/2,to.y+20);settle();
            check(Css.query(tree,view.node.id,".board-column[data-drop-target]").length==1,"Drag did not highlight a column");
        }
        function counts(expected:Array<Int>):Void {
            for(index => lane in ["To-do","In-progress","Done"]){
                var text=Css.query(tree,view.node.id,"#pocket-count-"+lane+" text");
                check(text.length==1 && ashui.ui.Text.at(text[0]).text()==Std.string(expected[index]),"Stale rendered count for "+lane);
            }
            var done=Css.query(tree,view.node.id,"#pocket-done-count");
            check(ashui.ui.Text.at(done[0]).text()==store.done()+" done","Completed count stopped observing tasks");
        }
        try {
            settle();
            check(Css.query(tree,view.node.id,".task-card").length==8,"Saved board did not render eight tasks");
            counts([3,3,2]);
            var inspector=bounds(".task-inspector"),title=bounds("#pocket-title"),description=bounds("#pocket-description");
            check(title.x>=inspector.x+16 && title.x+title.width<=inspector.x+inspector.width-16,"Title field escapes its inspector");
            check(description.x+description.width<=inspector.x+inspector.width-16,"Description field escapes its inspector");
            Snapshot.capture("pocket-board",tree,view.node,1100,740,ThemeState.get().color(Background).rgb());
            click("#pocket-add");var id=store.selected.get();
            check(store.tasks.get().length==9&&store.current().title=="New task","Add task control did not add/select a task");
            counts([4,3,2]);
            var titleNode=Css.query(tree,view.node.id,"#pocket-title")[0];
            check(ashui.ui.Input.at(tree,titleNode).value.get()=="New task","Inspector retained the previous task title");
            store.query.set("new task");settle();
            check(Css.query(tree,view.node.id,".task-card").length==1,"Task filter did not update the board");
            counts([1,0,0]);
            click("#pocket-next-"+id);check(store.current().lane=="In progress","Card action did not move the task");counts([0,1,0]);
            click("#pocket-advance");check(store.current().lane=="Done","Inspector action did not move the selected task");counts([0,0,1]);
            beginDrag(id,"To do");ashui.input.Pointer.release(tree);settle();counts([1,0,0]);
            beginDrag(id,"Done");ashui.input.Pointer.release(tree);settle();counts([0,0,1]);
            store.query.set("");settle();
            click("#pocket-title");ashui.input.Keyboard.text(tree," edited");settle();
            check(store.current().title.indexOf("edited")>=0,"Task title field did not update the board");
            click("#pocket-description");ashui.input.Keyboard.text(tree," changed");settle();
            check(store.current().description.indexOf("changed")>=0,"Task description field did not update the board");
            click("#pocket-save");
            var reopened=new BoardStore();check(reopened.tasks.get().length==9&&reopened.done()==3,"Save board did not preserve task transitions");
            click("#pocket-delete");check(store.tasks.get().length==8,"Delete task control did not remove the selected task");
            beginDrag(1,"Done");ashui.input.Pointer.release(tree);settle();
            check(store.current().id==1 && store.current().lane=="Done" && store.tasks.get().length==8,"Dropping a card did not move it without duplicating tasks");
            counts([3,2,3]);
            check(Css.query(tree,view.node.id,".board-drag-preview").length==0,"Drop retained its preview");
            beginDrag(1,"To do");ashui.input.Pointer.leave(tree);ashui.input.Pointer.release(tree);settle();
            check(store.current().lane=="Done" && Css.query(tree,view.node.id,".board-drag-preview").length==0,"Leaving the view committed a pending drop");
            beginDrag(1,"To do");
            ashui.input.Keyboard.input(tree,escape());ashui.input.Pointer.release(tree);settle();
            check(store.current().lane=="Done" && Css.query(tree,view.node.id,".board-drag-preview").length==0,"Escape committed a pending drop");
            click("#pocket-save");check(new BoardStore().tasks.get()[0].lane=="Done","Save lost the dragged lane");
            Snapshot.capture("pocket-board-edited",tree,view.node,1100,740,ThemeState.get().color(Background).rgb());
        } catch(error:Dynamic) {Sys.println(haxe.CallStack.toString(haxe.CallStack.exceptionStack()));stop();tree.dispose();Sys.setCwd(previous);throw error;}
        stop();tree.dispose();Sys.setCwd(previous);
        sys.FileSystem.deleteFile(scratch+"/data/tasks.json");sys.FileSystem.deleteDirectory(scratch+"/data");sys.FileSystem.deleteDirectory(scratch);
        Sys.println("Pocket Studio: inspector bounds, task editing, drag/drop, cancel/leave, filtering and saved lanes passed");
    }
    static function escape():window.KeyEvent return Input(Code(Escape),Named(Escape),None,Standard,Pressed,false,Unavailable);
}
