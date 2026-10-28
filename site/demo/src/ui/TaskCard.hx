package ui;

import ashui.components.Badge;
import ashui.components.Button;
import ashui.layout.Element;
import model.Task;
import state.BoardStore;

class TaskCard {
    public static function view(store:BoardStore, task:Task):Element {
        return <div class="task-card flex flex-col gap-3 p-3 rounded-lg" onClick={_ -> store.selected.set(task.id)}>
            <badge variant={Secondary}>${task.tag}</badge>
            <text class="font-semibold">${task.title}</text>
            <text class="text-xs text-text-secondary">${task.owner}</text>
            <button variant={Ghost} size={Sm} onClick={_ -> store.advance(task.id)}>Next stage</button>
        </div>;
    }
}
