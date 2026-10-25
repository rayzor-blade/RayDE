import ashui.css.Css;
import ashui.input.Scroll;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import rayde.keys.KeyBindings;
import rayde.run.Haxelib;
import rayde.ui.SettingsPage;
import rayde.workspace.Fs;
import rayde.workspace.Procs;

class SettingsChecks {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;
	static function main():Void {
		var disk = new CountingWorkspace(), previousFs = Fs.current, previousProcs = Procs.current;
		Fs.current = disk; disk.createDirectory("/work"); disk.createDirectory("/home/test");
		disk.saveContent("/work/.rayde/settings.json", '{}'); disk.saveContent("/home/test/.rayde/settings.json", '{}');
		var previousHome = Sys.getEnv("HOME"); Sys.putEnv("HOME", "/home/test");
		var launcher = new CatalogLauncher(); Procs.current = launcher; Haxelib.refresh();
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), Light); rayde.ui.Style.use();
		var tree = new LayoutTree(), category = Signal.make("keys"), stop:Void->Void = null;
		var commands = [for (i in 0...1000) {id:"test-" + i, label:"Command " + i, icon:rayde.ui.Icons.FILE_CODE_LINE, run:() -> {}}];
		var root = Owner.root(tree, cleanup -> {
			stop = cleanup;
			return new SettingsPage({category:category, root:"/work", manager:new rayde.ext.Manager("/work", {builtins:"",user:"",defaultEvents:[],restartLimit:0,restartWindow:60}), extensionChanges:Signal.make(0), onExtensionToggle:(_, _) -> {},
				build:null, rayzor:null, caribou:null, caribouLanguages:() -> [], onEditBuildText:() -> {}, beforeBuildChange:() -> {},
				terminal:rayde.term.Settings.read("/work"), appearance:rayde.settings.Appearance.read("/work"), bindings:new KeyBindings(false), bindingChanges:Signal.make(0),
				commands:commands, libraries:new rayde.run.LibraryManager("/work"), onBuildChanged:() -> {}, onTerminalChanged:() -> {}, onAppearanceChanged:() -> {}, onBindingsChanged:() -> {},
				extension:null, onExtensionChanged:_ -> {}, onEditExtensionText:() -> {}});
		});
		function settle():Void for (_ in 0...4) { Css.update(); tree.flush(); tree.computeLayout(root.node, 1100, 800); }
		function all(selector:String):Array<haxe.Int64> return Css.query(tree, root.node.id, selector);
		function node(selector:String):Node { var ids = all(selector); check(ids.length == 1, "Missing " + selector); return new Node(ids[0]); }
		try {
			settle();
			check(all(".rayde-key-row").length <= 18 && all(".rayde-key-row").length > 8, "Key bindings mounted the whole catalog");
			var navigation = all("#rayde-settings-nav-keys")[0], count = all("*").length;
			Scroll.at(node("#rayde-keys-list").id, tree).jumpTo(0, 100000); settle();
			check(all("#rayde-key-test-999").length == 1 && all("#rayde-key-test-0").length == 0, "Virtual rows did not reach the last command");
			ashui.ui.Input.at(tree, node("#rayde-keys-filter").id).value.set("Command 999"); settle();
			check(all(".rayde-key-row").length == 1 && all("#rayde-key-test-999").length == 1, "Filtering lost an offscreen command");
			for (_ in 0...5) {
				category.set("terminal"); settle(); check(all(".rayde-key-row").length == 0, "Inactive section retained rows");
				category.set("keys"); settle(); check(all("*").length <= count + 2, "Repeated section switching retained elements");
				check(all("#rayde-settings-nav-keys")[0] == navigation, "Navigation rows were rebuilt");
			}
			category.set("libraries"); settle();
			launcher.entered.await();
			var a = Haxelib.installedAsync(), b = Haxelib.installedAsync();
			check(!a.isReady() && a == b && all("#rayde-library-loading").length == 1, "Library rendering waited for haxelib or duplicated its query");
			category.set("terminal"); settle(); check(!a.isReady(), "Navigation waited for the catalog");
			launcher.release.resolve(true); check(a.await().length == 200, "Catalog did not finish");
			category.set("libraries"); settle();
			check(all(".rayde-lib-row").length <= 15 && all(".rayde-lib-row").length > 5, "Libraries mounted the whole catalog");
			Scroll.at(node("#rayde-library-list").id, tree).jumpTo(0, 100000); settle();
			check(all("#rayde-lib-lib199").length == 1, "Virtual libraries lost the final row");
			check(launcher.calls == 1, "Reopening libraries repeated the process query");
			Haxelib.refresh(); launcher.entered = new ash.Future<Bool>(); launcher.gate = new ash.Future<Bool>(); launcher.text = "stale: [1]";
			var staleGate = launcher.gate, stale = Haxelib.installedAsync(); launcher.entered.await();
			Haxelib.refresh(); launcher.entered = new ash.Future<Bool>(); launcher.gate = new ash.Future<Bool>(); launcher.text = "fresh: [2]";
			var fresh = Haxelib.installedAsync(); launcher.entered.await(); launcher.gate.resolve(true);
			check(fresh.await()[0].name == "fresh", "Refreshed catalog did not complete");
			staleGate.resolve(true); stale.await(); check(Haxelib.installed()[0].name == "fresh", "An older query overwrote the refreshed catalog");
			var reads = disk.reads;
			Owner.root(tree, cleanup -> {
				var properties = {}; for (i in 0...12) Reflect.setField(properties, "flag" + i, {type:"boolean"});
				new rayde.ui.ExtensionConfiguration({root:"/work",id:"example",schema:{properties:properties}});
				cleanup();
			});
			check(disk.reads - reads == 2, "Extension configuration reread settings for every field");
			Sys.println("Settings: virtual rows, navigation lifetime, async libraries and batched reads passed");
		} catch (error:Dynamic) { stop(); Fs.current = previousFs; Procs.current = previousProcs; throw error; }
		stop(); Fs.current = previousFs; Procs.current = previousProcs; Sys.putEnv("HOME", previousHome); Haxelib.refresh();
	}
}

private class CountingWorkspace extends rayde.workspace.MemoryWorkspace {
	public var reads = 0;
	override public function getContent(path:String):String { reads++; return super.getContent(path); }
}
private class CatalogLauncher implements rayde.workspace.Launcher {
	public var entered = new ash.Future<Bool>();
	public final release = new ash.Future<Bool>();
	public var calls = 0;
	public var gate:ash.Future<Bool>;
	public var text = [for (i in 0...200) 'lib$i: [1.0]'].join("\n");
	public function new() { gate = release; }
	public function start(command:String, args:Array<String>):rayde.workspace.Program {
		calls++; var wait = gate, output = text; entered.resolve(true); wait.await();
		return new CatalogProgram(output);
	}
}
private class CatalogProgram implements rayde.workspace.Program {
	public var stdout(default,null):haxe.io.Input;
	public var stderr(default,null):haxe.io.Input = new haxe.io.StringInput("");
	public var stdin(default,null):haxe.io.Output = new haxe.io.BytesOutput();
	public function new(text:String) { stdout = new haxe.io.StringInput(text); }
	public function exitCode(block = true):Null<Int> return 0;
	public function kill():Void {}
	public function close():Void {}
}
