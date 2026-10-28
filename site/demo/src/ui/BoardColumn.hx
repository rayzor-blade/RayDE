package ui;

import ashui.components.Badge;
import ashui.layout.Element;
import state.BoardStore;

class BoardColumn {
    public static function view(store:BoardStore, lane:String):Element {
        return <div class="board-column flex flex-col flex-1 min-w-0 min-h-0 p-3 gap-3 rounded-lg">
            <div class="flex items-center gap-2 shrink-0">
                <text class="font-semibold flex-1">${lane}</text>
                <badge variant={Secondary}>${store.inLane(lane).length}</badge>
            </div>
            <div class="flex flex-col gap-3 overflow-y-auto flex-1 min-h-0">
                <for {task in store.inLane(lane)}>${TaskCard.view(store, task)}</for>
                <if {store.inLane(lane).length == 0}><text class="text-xs text-text-secondary p-2">Room for something new.</text></if>
            </div>
        </div>;
    }
}
