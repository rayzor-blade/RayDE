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
        var tree=new LayoutTree(), app:BoardApp=null, stop:Void->Void=null;
        var view=Owner.root(tree,cleanup -> {stop=cleanup;app=new BoardApp();return app.render();});
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
        try {
            settle();
            check(Css.query(tree,view.node.id,".task-card").length==8,"Saved board did not render eight tasks");
            Snapshot.capture("pocket-board",tree,view.node,1100,740,ThemeState.get().color(Background).rgb());
            click("#pocket-add");var id=app.store.selected.get();
            check(app.store.tasks.get().length==9&&app.store.current().title=="New task","Add task control did not add/select a task");
            app.store.query.set("new task");settle();
            check(Css.query(tree,view.node.id,".task-card").length==1,"Task filter did not update the board");
            click("#pocket-next-"+id);check(app.store.current().lane=="In progress","Card action did not move the task");
            click("#pocket-advance");check(app.store.current().lane=="Done","Inspector action did not move the selected task");
            app.store.query.set("");settle();
            click("#pocket-title");ashui.input.Keyboard.text(tree," edited");settle();
            check(app.store.current().title.indexOf("edited")>=0,"Task title field did not update the board");
            click("#pocket-description");ashui.input.Keyboard.text(tree," changed");settle();
            check(app.store.current().description.indexOf("changed")>=0,"Task description field did not update the board");
            click("#pocket-save");
            var reopened=new BoardStore();check(reopened.tasks.get().length==9&&reopened.done()==3,"Save board did not preserve task transitions");
            click("#pocket-delete");check(app.store.tasks.get().length==8,"Delete task control did not remove the selected task");
            Snapshot.capture("pocket-board-edited",tree,view.node,1100,740,ThemeState.get().color(Background).rgb());
        } catch(error:Dynamic) {stop();tree.dispose();Sys.setCwd(previous);throw error;}
        stop();tree.dispose();Sys.setCwd(previous);
        sys.FileSystem.deleteFile(scratch+"/data/tasks.json");sys.FileSystem.deleteDirectory(scratch+"/data");sys.FileSystem.deleteDirectory(scratch);
        Sys.println("Pocket Studio: published dependencies, rendered board, add/select, both move controls, filter and save/reopen passed");
    }
}
