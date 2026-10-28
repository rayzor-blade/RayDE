package ui;

import ashui.components.Badge;
import ashui.components.Button;
import ashui.layout.Element;
import state.BoardStore;

class TaskInspector {
    public static function view(store:BoardStore):Element {
        return <div class="task-inspector flex flex-col shrink-0 p-4 gap-4 rounded-lg">
            <text class="text-xs text-text-secondary">TASK DETAILS</text>
            <if {store.current() != null}>
                <text class="text-xl font-semibold">${store.current().title}</text>
                <badge variant={Primary}>${store.current().lane}</badge>
                <text class="text-sm text-text-secondary">${store.current().description}</text>
                <text class="text-sm">Owner: ${store.current().owner}</text>
                <button variant={Outline} onClick={_ -> store.advance(store.selected.get())}>Move to next stage</button>
            </if>
        </div>;
    }
}
