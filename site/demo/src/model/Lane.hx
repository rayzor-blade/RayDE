package model;

enum abstract Lane(String) to String {
    var Ideas = "Ideas";
    var Building = "Building";
    var Shipped = "Shipped";

    public static function next(value:String):String {
        return switch value {
            case Ideas: Building;
            case Building: Shipped;
            case _: Ideas;
        };
    }
}
