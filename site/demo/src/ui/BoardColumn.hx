package ui;

import ashui.components.Badge;
import ashui.layout.Element;
import ashui.ui.Component;
import state.BoardStore;

typedef BoardColumnProps = {store:BoardStore, lane:String};

class BoardColumn extends Component<BoardColumnProps> {
    function render():Element {
        return <div class="board-column flex flex-col flex-1 min-w-0 min-h-0 p-3 gap-3 rounded-lg">
            <div class="flex items-center gap-2 shrink-0">
                <text class="font-semibold flex-1">${props.lane}</text>
                <badge variant={Secondary}>${props.store.inLane(props.lane).length}</badge>
            </div>
            <div class="flex flex-col gap-3 overflow-y-auto flex-1 min-h-0">
                <for {task in props.store.inLane(props.lane)}><task-card store={props.store} task={task}/></for>
                <if {props.store.inLane(props.lane).length == 0}><text class="text-xs text-text-secondary p-2">Room for something new.</text></if>
            </div>
        </div>;
    }
}
