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
                <text class="text-sm text-text-secondary">Small ideas. A little momentum.</text>
            </div>
            <input class="task-search" placeholder="Find a task…" value={store.query}/>
            <button variant={Outline} onClick={_ -> store.save()}>Save board</button>
            <button onClick={_ -> store.add()}><icon document={Remix.ADD_LINE} class="size-4"/>New idea</button>
        </div>;
    }
}
