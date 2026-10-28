package ui;

import ashui.layout.Element;
import state.BoardStore;

class BoardStats {
    public static function view(store:BoardStore):Element {
        return <div class="board-stats flex gap-5 items-center p-3 rounded-lg shrink-0">
            <text class="text-sm">${store.tasks.get().length} tasks on the board</text>
            <text class="text-sm text-success">${store.done()} done</text>
            <text class="text-xs text-text-secondary flex-1">Haxe + Ashui + a little RayScript</text>
        </div>;
    }
}
