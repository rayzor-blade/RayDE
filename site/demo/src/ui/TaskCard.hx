package ui;

import ashui.components.Badge;
import ashui.components.Button;
import ashui.layout.Element;
import ashui.ui.Component;
import model.Task;
import state.BoardStore;

typedef TaskCardProps = {store:BoardStore, task:Task};

class TaskCard extends Component<TaskCardProps> {
    function render():Element {
        return <div id={"pocket-task-" + props.task.id} class="task-card flex flex-col gap-3 p-3 rounded-lg" onClick={_ -> props.store.selected.set(props.task.id)}>
            <badge variant={Secondary}>${props.task.tag}</badge>
            <text class="font-semibold">${props.task.title}</text>
            <text class="text-xs text-text-secondary">${props.task.owner}</text>
            <button id={"pocket-next-" + props.task.id} variant={Ghost} size={Sm} onClick={_ -> props.store.advance(props.task.id)}>Next stage</button>
        </div>;
    }
}
