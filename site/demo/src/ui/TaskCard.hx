package ui;

import ashui.components.Badge;
import ashui.components.Button;
import ashui.layout.Element;
import ashui.ui.Component;
import model.Task;
import state.BoardStore;

typedef TaskCardProps = {store:BoardStore, task:Task, drag:BoardDrag};

class TaskCard extends Component<TaskCardProps> {
    function render():Element {
        var card=<div id={"pocket-task-" + props.task.id} class="task-card flex flex-col gap-3 p-3 rounded-lg" onPointerDown={event -> props.drag.begin(props.task,event)} onClick={_ -> {if(!props.drag.suppressClick())props.store.selected.set(props.task.id);}}>
            <badge variant={Secondary}>${props.task.tag}</badge>
            <text class="font-semibold">${props.task.title}</text>
            <text class="text-xs text-text-secondary">${props.task.owner}</text>
            <button id={"pocket-next-" + props.task.id} variant={Ghost} size={Sm} onPointerDown={event -> event.stopPropagation()} onClick={event -> {event.stopPropagation();props.store.advance(props.task.id);}}>Next stage</button>
        </div>;
        ashui.input.Interaction.of(card.node).setFocusable(true);
        ashui.css.Identity.of(card.tree,card.node.id).bindBooleanAttribute("data-dragging",ashui.reactive.Computed.make(() -> props.drag.task.get()!=null&&props.drag.task.get().id==props.task.id));
        return card;
    }
}
