package ui;

import ashui.layout.Element;
import ashui.ui.Component;
import ashui.reactive.Computed;
import state.BoardStore;

typedef BoardStatsProps = {store:BoardStore};

class BoardStats extends Component<BoardStatsProps> {
    function render():Element {
        var done=Computed.make(() -> props.store.done());
        return <div class="board-stats flex gap-5 items-center p-3 rounded-lg shrink-0">
            <text class="text-sm">${props.store.tasks.get().length} tasks on the board</text>
            <text id="pocket-done-count" class="text-sm text-success">${done.get()} done</text>
            <text class="text-xs text-text-secondary flex-1">Haxe + Ashui + a little RayScript</text>
        </div>;
    }
}
