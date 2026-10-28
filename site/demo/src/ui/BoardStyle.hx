package ui;

class BoardStyle {
    static var installed = false;

    public static function use():Void {
        if (installed) return;
        ashui.css.Css.add(ashui.css.CompiledCss.file("../../styles/app.css"));
        installed = true;
    }
}
