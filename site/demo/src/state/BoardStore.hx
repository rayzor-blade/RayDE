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
        for(task in tasks.get())if(task.id==id){move(id,Lane.next(task.lane));return;}
    }

    public function move(id:Int,lane:String):Void {
        if(["To do","In progress","Done"].indexOf(lane)<0)return;
        var current=tasks.get().filter(task -> task.id==id)[0];
        if(current==null||current.lane==lane)return;
        tasks.set([for (task in tasks.get()) task.id != id ? task : {
            id:task.id, title:task.title, description:task.description,
            lane:lane, tag:task.tag, owner:task.owner
        }]);
        selected.set(id);message.set("Moved task to " + lane + ". Save the board to keep your changes.");
    }

    public function add():Void {
        var id = 1;
        for (task in tasks.get()) if (task.id >= id) id = task.id + 1;
        tasks.set(tasks.get().concat([{id:id, title:"New task", description:"Add a description for this task.", lane:Lane.ToDo, tag:"Idea", owner:"You"}]));
        selected.set(id); message.set("Add task added. Try changing its component or stylesheet.");
    }

    public function update(id:Int, ?title:String, ?description:String):Void {
        tasks.set([for (task in tasks.get()) task.id != id ? task : {
            id:task.id, title:title ?? task.title, description:description ?? task.description,
            lane:task.lane, tag:task.tag, owner:task.owner
        }]);
        message.set("Task updated. Save the board to keep your changes.");
    }

    public function remove(id:Int):Void {
        tasks.set(tasks.get().filter(task -> task.id != id));
        selected.set(tasks.get().length == 0 ? 0 : tasks.get()[0].id);
        message.set("Task deleted. Save the board to keep your changes.");
    }

    public function done():Int return tasks.get().filter(task -> task.lane == Lane.Done).length;

    public function save():Void {
        sys.io.File.saveContent("data/tasks.json", TaskData.export(tasks.get()));
        message.set("Saved data/tasks.json. Refresh Pocket Tools to read the new snapshot.");
    }
}
