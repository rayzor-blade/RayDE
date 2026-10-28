import ashui.app.WindowedApp;
import ui.BoardApp;

/** Pocket Studio: a Haxe/Ashui app and a RayScript extension to explore in RayDE. */
class Main {
    static function main() {
        WindowedApp.run({title: "Pocket Studio", width: 1100, height: 740}, () -> {
            return new BoardApp().render();
        });
    }
}
