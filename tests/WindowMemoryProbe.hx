import ashui.app.WindowedApp;
import ashui.animation.AnimationScheduler;
import ashui.css.Css;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

/** Visits code tabs in a native window and checkpoints their lifetime for memory_probe.py. */
@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.CodeActionsPart)
@:access(rayde.ui.workbench.DebugPart)
@:access(rayde.ui.workbench.DocumentsPart)
@:access(rayde.ui.workbench.EditorMarksPart)
@:access(rayde.ui.workbench.EditorPart)
@:access(rayde.ui.workbench.ExplorerPart)
@:access(rayde.ui.workbench.ExtensionsPart)
@:access(rayde.ui.workbench.KeymapPart)
@:access(rayde.ui.workbench.LanguagesPart)
@:access(rayde.ui.workbench.MenusPart)
@:access(rayde.ui.workbench.PanelsPart)
@:access(rayde.ui.workbench.ProjectPart)
@:access(rayde.ui.workbench.RunPart)
@:access(rayde.ui.workbench.ShellPart)
@:access(rayde.ui.workbench.TerminalPart)
@:access(rayde.ui.workbench.ThemePart)
class WindowMemoryProbe {
	static function main():Void {
		var root = Sys.getCwd() + "bin/window-memory-workspace";
		sys.FileSystem.createDirectory(root + "/src");
		sys.io.File.saveContent(root + "/build.hxml", "-cp src\n-main Main\n");
		sys.io.File.saveContent(root + "/src/Main.hx", "class Main { static function main() {} }\n");
		var files:Array<String> = [], count = Std.parseInt(Sys.getEnv("WINDOW_MEMORY_FILES") ?? "65");
		for (i in 0...count) {
			var file = root + '/src/File$i.hx';
			sys.io.File.saveContent(file, 'class File$i {\n' + [for (j in 0...80) ' public function method$j(value:Int):Int { return value + $j; }\n'].join("") + "}\n");
			files.push(file);
		}
		var server = new CompilerServer(), bench:Workbench = null;
		rayde.ui.Style.use();
		WindowedApp.run({title:"Window memory probe", width:1280, height:800, decorations:false, transparent:true,
			theme:ashui.theme.themes.RestrainedTheme.bundle()}, () -> {
			var app = WindowedApp.current, ack = Sys.getEnv("WELCOME_MEMORY_ACK");
			bench = new Workbench({display:Display.ofHxml(server, root + "/build.hxml"), name:"Memory probe", runtime:"ash"});
			rayde.ui.GpuProgress.attach(app.device, app.tree, () -> app.frames);
			function later(seconds:Float, fn:Void->Void):Void AnimationScheduler.main.after(seconds, fn);
			function checkpoint(phase:String, next:Void->Void):Void {
				hl.Gc.major(); app.device.poll();
				later(2, () -> {
					var heap = hl.Gc.stats(), editors = 0, watches = 0;
					@:privateAccess for (watch in ashui.reactive.Watch.bySlot) if (watch != null) watches++;
					@:privateAccess for (owner => component in ashui.ui.Component.hosts)
						if (!owner.disposed && Std.isOfType(component, ashui.components.CodeEditor)) editors++;
					Sys.println("welcome-memory:" + haxe.Json.stringify({mode:phase, tabs:bench.open.get().length,
						nodes:app.tree.order().length, editors:editors, watches:watches, gcHeapBytes:heap.currentMemory,
						tokens:Css.query(app.tree, bench.node.id, ".ui-code-token").length, totalAllocatedBytes:heap.totalAllocated}));
					Sys.stdout().flush();
					if (Sys.getEnv("MEMORY_PROBE_DUMP") == "1") hl.Gc.dumpMemory(ack + "." + phase + ".heap");
					var deadline = haxe.Timer.stamp() + 90;
					function wait():Void {
						if (sys.FileSystem.exists(ack)) { sys.FileSystem.deleteFile(ack); next(); }
						else if (haxe.Timer.stamp() > deadline) throw "Memory sampler timed out";
						else later(.05, wait);
					}
					wait();
				});
			}
			function visit(index:Int):Void {
				if (index == files.length) {
					checkpoint("tabs-open", () -> {
						bench.closeAll();
						later(2, () -> checkpoint("tabs-closed", () -> later(10, () -> checkpoint("closed-idle", app.quit))));
					});
					return;
				}
				bench.openFile(files[index]);
				later(.08, () -> visit(index + 1));
			}
			later(2, () -> checkpoint("baseline", () -> visit(0)));
			return bench;
		});
		server.stop();
	}
}
