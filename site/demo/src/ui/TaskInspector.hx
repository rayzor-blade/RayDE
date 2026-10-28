package ui;

import ashui.components.Badge;
import ashui.components.Button;
import ashui.components.Input;
import ashui.components.Textarea;
import ashui.layout.Element;
import state.BoardStore;

class TaskInspector {
    public static function view(store:BoardStore):Element {
        return <div class="task-inspector flex flex-col shrink-0 p-4 gap-4 rounded-lg">
            <text class="text-xs text-text-secondary">TASK DETAILS</text>
            <if {store.current() != null}>
                <input id="pocket-title" value={store.current().title} onInput={text -> store.update(store.selected.get(),text)}/>
                <badge variant={Primary}>${store.current().lane}</badge>
                <textarea id="pocket-description" class="h-32" value={store.current().description} onInput={text -> store.update(store.selected.get(),null,text)}/>
                <text class="text-sm">Owner: ${store.current().owner}</text>
                <button id="pocket-advance" variant={Outline} onClick={_ -> store.advance(store.selected.get())}>Move to next stage</button>
                <button id="pocket-delete" variant={Ghost} class="text-error" onClick={_ -> store.remove(store.selected.get())}>Delete task</button>
            </if>
        </div>;
    }
}
