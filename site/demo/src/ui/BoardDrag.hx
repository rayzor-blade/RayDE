package ui;

import ashui.input.Events.PointerEvent;
import ashui.input.Pointer;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.reactive.Signal;
import model.Task;
import state.BoardStore;

/** Ashui's pointer hook follows the gesture across cards and clipped scroll containers. */
class BoardDrag {
    public final task = Signal.make((null:Null<Task>));
    public final target = Signal.make("");
    public final x = Signal.make(0.);
    public final y = Signal.make(0.);
    final store:BoardStore;
    final columns = new Map<String,Element>();
    var root:Element;
    var pending:Null<Task>;
    var startX = 0.;
    var startY = 0.;
    var suppressed = false;
    var hook:Null<LayoutTree->Void>;

    public function new(store:BoardStore) this.store = store;
    public function attach(root:Element):Void this.root = root;
    public function column(lane:String,element:Element):Void {
        columns.set(lane,element);
        ashui.reactive.Owner.onCleanup(() -> {if(columns.get(lane)==element)columns.remove(lane);});
    }
    public function suppressClick():Bool return suppressed;
    public function begin(value:Task,event:PointerEvent):Void {
        if(event.button==null||!event.button.match(Left))return;
        cancel();suppressed=false;pending=value;startX=event.x;startY=event.y;
        hook=tree -> {if(tree==root.tree)update();};Pointer.hooks.push(hook);
    }
    public function cancel():Void {
        if(hook!=null)Pointer.hooks.remove(hook);hook=null;
        if(task.get()!=null)suppressed=true;
        pending=null;task.set(null);target.set("");
    }
    function update():Void {
        if(pending==null)return;
        var point=Pointer.at(root.tree);
        if(!point.inside){cancel();return;}
        if(task.get()==null&&point.pressed){
            var dx=point.x-startX,dy=point.y-startY;
            if(dx*dx+dy*dy<36)return;
            task.set(pending);suppressed=true;
        }
        var lane="";
        if(task.get()!=null){
            var hits=root.tree.hitTest(point.x,point.y);
            for(name => column in columns)if(Lambda.exists(hits,hit -> hit.id==column.node.id)){lane=name;break;}
        }
        if(!point.pressed){var value=pending,move=task.get()!=null;cancel();if(move&&lane!="")store.move(value.id,lane);return;}
        if(task.get()==null)return;
        target.set(lane);
        var bounds=root.tree.getScrolledBounds(root.node);
        x.set(point.x-bounds.x+12);y.set(point.y-bounds.y+12);
    }
}
