package model;

enum abstract Lane(String) to String {
    var ToDo = "To do";
    var InProgress = "In progress";
    var Done = "Done";

    public static function next(value:String):String {
        return switch value {
            case ToDo: InProgress;
            case InProgress: Done;
            case _: ToDo;
        };
    }
}
