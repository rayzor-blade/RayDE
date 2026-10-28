package ui;

import ashui.layout.Element;
import ashui.ui.Component;
import state.BoardStore;

/** HXX composes typed components; each child observes the signals it reads. */
typedef BoardAppProps = {store:BoardStore};

class BoardApp extends Component<BoardAppProps> {
    function render():Element {
        BoardStyle.use();
        return <div class="pocket-app flex flex-col w-full h-full min-h-0 bg-background text-text-primary p-6 gap-5">
            <board-header store={props.store}/>
            <board-stats store={props.store}/>
            <div class="flex flex-wrap flex-1 min-h-0 gap-4 overflow-y-auto">
                <div class="board-lanes flex flex-1 gap-3">
                    <board-column store={props.store} lane="To do"/>
                    <board-column store={props.store} lane="In progress"/>
                    <board-column store={props.store} lane="Done"/>
                </div>
                <task-inspector store={props.store}/>
            </div>
            <text class="text-xs text-text-secondary">${props.store.message.get()}</text>
        </div>;
    }
}
