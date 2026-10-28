import ashui.app.WindowedApp;
import ui.BoardApp;
import state.BoardStore;

/** Pocket Studio: a Haxe/Ashui app and a RayScript extension to explore in RayDE. */
class Main {
    static function main() {
        var store = new BoardStore();
        WindowedApp.run({title: "Pocket Studio", width: 1100, height: 740}, () -> {
            return <board-app store={store}/>;
        });
    }
}
