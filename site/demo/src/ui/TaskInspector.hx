package ui;

import ashui.components.Badge;
import ashui.components.Button;
import ashui.components.Input;
import ashui.components.Textarea;
import ashui.layout.Element;
import ashui.ui.Component;
import ashui.reactive.Signal;
import ashui.reactive.Computed;
import ashui.reactive.Watch;
import state.BoardStore;

typedef TaskInspectorProps = {store:BoardStore};

class TaskInspector extends Component<TaskInspectorProps> {
    function render():Element {
        var task=Computed.make(() -> props.store.current());
        var title=Computed.make(() -> task.get()==null ? "" : task.get().title);
        var lane=Computed.make(() -> task.get()==null ? "" : task.get().lane);
        var owner=Computed.make(() -> task.get()==null ? "" : task.get().owner);
        var description = Signal.make("");
        new Watch(() -> task.get() == null ? "" : task.get().description, value -> description.set(value));
        return <div class="task-inspector flex flex-col shrink-0 p-4 gap-4 rounded-lg">
            <text class="text-xs text-text-secondary">TASK DETAILS</text>
            <if {task.get() != null}>
                <input id="pocket-title" value={title} onInput={text -> props.store.update(props.store.selected.get(),text)}/>
                <badge variant={Primary}>${lane.get()}</badge>
                <textarea id="pocket-description" height={160} value={description} onInput={text -> props.store.update(props.store.selected.get(),null,text)}/>
                <text class="text-sm">Owner: ${owner.get()}</text>
                <button id="pocket-advance" variant={Outline} onClick={_ -> props.store.advance(props.store.selected.get())}>Move to next stage</button>
                <button id="pocket-delete" variant={Ghost} class="text-error" onClick={_ -> props.store.remove(props.store.selected.get())}>Delete task</button>
            </if>
        </div>;
    }
}
