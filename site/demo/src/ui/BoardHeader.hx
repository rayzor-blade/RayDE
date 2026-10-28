package ui;

import ashui.components.Button;
import ashui.components.Input;
import ashui.components.Icon;
import ashui.icons.Remix;
import ashui.layout.Element;
import state.BoardStore;

class BoardHeader {
    public static function view(store:BoardStore):Element {
        return <div class="flex items-center gap-4 shrink-0">
            <icon document={Remix.LAYOUT_MASONRY_LINE} class="size-7 text-primary"/>
            <div class="flex flex-col gap-1 flex-1">
                <text class="text-2xl font-semibold">Pocket Studio</text>
                <text class="text-sm text-text-secondary">Your tasks, from to do to done.</text>
            </div>
            <input id="pocket-search" class="task-search" placeholder="Find a task…" value={store.query}/>
            <button id="pocket-save" variant={Outline} onClick={_ -> store.save()}>Save board</button>
            <button id="pocket-add" onClick={_ -> store.add()}><icon document={Remix.ADD_LINE} class="size-4"/>Add task</button>
        </div>;
    }
}
