package ui;

import ashui.components.Badge;
import ashui.components.Button;
import ashui.components.Input;
import ashui.components.Textarea;
import ashui.layout.Element;
import ashui.ui.Component;
import ashui.reactive.Signal;
import ashui.reactive.Watch;
import state.BoardStore;

typedef TaskInspectorProps = {store:BoardStore};

class TaskInspector extends Component<TaskInspectorProps> {
    function render():Element {
        var description = Signal.make("");
        new Watch(() -> props.store.current() == null ? "" : props.store.current().description, value -> description.set(value));
        return <div class="task-inspector flex flex-col shrink-0 p-4 gap-4 rounded-lg">
            <text class="text-xs text-text-secondary">TASK DETAILS</text>
            <if {props.store.current() != null}>
                <input id="pocket-title" value={props.store.current().title} onInput={text -> props.store.update(props.store.selected.get(),text)}/>
                <badge variant={Primary}>${props.store.current().lane}</badge>
                <div id="pocket-description" class="flex flex-col"><textarea width={190} height={160} value={description} onInput={text -> props.store.update(props.store.selected.get(),null,text)}/></div>
                <text class="text-sm">Owner: ${props.store.current().owner}</text>
                <button id="pocket-advance" variant={Outline} onClick={_ -> props.store.advance(props.store.selected.get())}>Move to next stage</button>
                <button id="pocket-delete" variant={Ghost} class="text-error" onClick={_ -> props.store.remove(props.store.selected.get())}>Delete task</button>
            </if>
        </div>;
    }
}
