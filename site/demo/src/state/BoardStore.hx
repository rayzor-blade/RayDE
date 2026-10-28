package state;

import ashui.reactive.Signal;
import model.Task;
import model.Lane;
import services.TaskData;

/** Shared state is independent of the components that display it. */
class BoardStore {
    public final tasks = Signal.make(TaskData.load());
    public final query = Signal.make("");
    public final selected = Signal.make(1);
    public final message = Signal.make("Choose a task to explore its details.");

    public function new() {}

    public function inLane(lane:String):Array<Task> {
        var text = query.get().toLowerCase();
        return tasks.get().filter(task -> task.lane == lane &&
            (text == "" || (task.title + " " + task.tag + " " + task.owner).toLowerCase().indexOf(text) >= 0));
    }

    public function current():Null<Task> {
        for (task in tasks.get()) if (task.id == selected.get()) return task;
        return null;
    }

    public function advance(id:Int):Void {
        tasks.set([for (task in tasks.get()) task.id != id ? task : {
            id:task.id, title:task.title, description:task.description,
            lane:Lane.next(task.lane), tag:task.tag, owner:task.owner
        }]);
        message.set("Moved task " + id + " to its next stage.");
    }

    public function add():Void {
        var id = 1;
        for (task in tasks.get()) if (task.id >= id) id = task.id + 1;
        tasks.set(tasks.get().concat([{id:id, title:"A new idea", description:"Make this idea your own.", lane:Lane.Ideas, tag:"Idea", owner:"You"}]));
        selected.set(id); message.set("New idea added. Try changing its component or stylesheet.");
    }

    public function shipped():Int return tasks.get().filter(task -> task.lane == Lane.Shipped).length;

    public function save():Void {
        sys.io.File.saveContent("data/tasks.json", TaskData.export(tasks.get()));
        message.set("Saved data/tasks.json. Refresh Pocket Tools to read the new snapshot.");
    }
}
