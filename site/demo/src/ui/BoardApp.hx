package ui;

import ashui.layout.Element;
import ashui.ui.Component;
import ashui.types.Style;
import state.BoardStore;

/** HXX composes typed components; each child observes the signals it reads. */
typedef BoardAppProps = {store:BoardStore};

class BoardApp extends Component<BoardAppProps> {
    function render():Element {
        BoardStyle.use();
        var drag=new BoardDrag(props.store);
        var root=<div class="pocket-app relative flex flex-col w-full h-full min-h-0 bg-background text-text-primary p-6 gap-5">
            <board-header store={props.store}/>
            <board-stats store={props.store}/>
            <div class="flex flex-wrap flex-1 min-h-0 gap-4 overflow-y-auto">
                <div class="board-lanes flex flex-1 gap-3">
                    <board-column store={props.store} lane="To do" drag={drag}/>
                    <board-column store={props.store} lane="In progress" drag={drag}/>
                    <board-column store={props.store} lane="Done" drag={drag}/>
                </div>
                <task-inspector store={props.store}/>
            </div>
            <text class="text-xs text-text-secondary">${props.store.message.get()}</text>
            <for {task in (drag.task.get()==null ? [] : [drag.task.get()])}><div class="board-drag-preview flex flex-col gap-2 p-3 rounded-lg" position={Absolute} left={drag.x} top={drag.y} pointerEvents={PointerEvents.None}>
                <text class="font-semibold">${task.title}</text><text class="text-xs text-text-secondary">${task.owner}</text>
            </div></for>
        </div>;
        drag.attach(root);
        ashui.input.Interaction.of(root.node).onKeyDown(event -> {if(event.key.match(Named(Escape))&&drag.task.get()!=null){drag.cancel();event.preventDefault();event.stopPropagation();}});
        ashui.reactive.Owner.onCleanup(drag.cancel);
        return root;
    }
}
