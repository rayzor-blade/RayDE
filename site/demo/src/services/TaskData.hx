package services;

import model.Task;

/** The same JSON is read by the companion extension's workspace summary. */
class TaskData {
    public static function load():Array<Task> {
        return cast haxe.Json.parse(sys.io.File.getContent("data/tasks.json"));
    }

    public static function export(tasks:Array<Task>):String {
        return haxe.Json.stringify(tasks, null, "  ");
    }
}
