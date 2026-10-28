package ui;

import ashui.components.Button;
import ashui.components.Input;
import ashui.components.Icon;
import ashui.icons.Remix;
import ashui.layout.Element;
import ashui.ui.Component;
import state.BoardStore;

typedef BoardHeaderProps = {store:BoardStore};

class BoardHeader extends Component<BoardHeaderProps> {
    function render():Element {
        return <div class="flex flex-col gap-3 shrink-0">
          <div class="flex items-center gap-3">
            <icon document={Remix.LAYOUT_MASONRY_LINE} class="size-7 text-primary"/>
            <div class="flex flex-col gap-1 flex-1">
                <text class="text-2xl font-semibold">Pocket Studio</text>
                <text class="text-sm text-text-secondary">Your tasks, from to do to done.</text>
            </div>
          </div>
          <div class="flex items-center gap-3">
            <input id="pocket-search" class="task-search flex-1 min-w-0" placeholder="Find a task…" value={props.store.query}/>
            <button id="pocket-save" variant={Outline} onClick={_ -> props.store.save()}>Save board</button>
            <button id="pocket-add" onClick={_ -> props.store.add()}><icon document={Remix.ADD_LINE} class="size-4"/>Add task</button>
          </div>
        </div>;
    }
}
