package ui;

import ashui.components.Badge;
import ashui.layout.Element;
import ashui.ui.Component;
import ashui.reactive.Computed;
import state.BoardStore;

typedef BoardColumnProps = {store:BoardStore, lane:String, drag:BoardDrag};

class BoardColumn extends Component<BoardColumnProps> {
    function render():Element {
        var tasks=Computed.make(() -> props.store.inLane(props.lane));
        var column=<div id={"pocket-lane-"+props.lane.split(" ").join("-")} class="board-column flex flex-col flex-1 min-w-0 min-h-0 p-3 gap-3 rounded-lg">
            <div class="flex items-center gap-2 shrink-0">
                <text class="font-semibold flex-1">${props.lane}</text>
                <badge id={"pocket-count-"+props.lane.split(" ").join("-")} variant={Secondary}>${tasks.get().length}</badge>
            </div>
            <div class="flex flex-col gap-3 overflow-y-auto flex-1 min-h-0">
                <for {task in tasks}><task-card store={props.store} task={task} drag={props.drag}/></for>
                <if {tasks.get().length == 0}><text class="text-xs text-text-secondary p-2">Room for something new.</text></if>
            </div>
        </div>;
        props.drag.column(props.lane,column);
        ashui.css.Identity.of(column.tree,column.node.id).bindBooleanAttribute("data-drop-target",ashui.reactive.Computed.make(() -> props.drag.target.get()==props.lane));
        return column;
    }
}
