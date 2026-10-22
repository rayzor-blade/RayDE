import ashui.animation.AnimationScheduler;
import ashui.app.WindowedApp;
import ashui.components.CodeEditor;
import ashui.css.Css;
import ashui.layout.Element;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.ui.Ref;
import rayde.ui.DocumentState;

/** Isolates the mounted editor from extension VMs, LSP processes and other tab data. */
class EditorMemoryProbe {
	static function main():Void {
		var mode = Sys.getEnv("WELCOME_MEMORY_MODE"), ack = Sys.getEnv("WELCOME_MEMORY_ACK");
		var file = Sys.getEnv("EDITOR_MEMORY_FILE") ?? "tests/ExplorerMemoryProbe.hx";
		var state = new DocumentState(Signal.make(sys.io.File.getContent(file))), shown = Signal.make(false), ref = new Ref<CodeEditor>();
		var appearance = rayde.settings.Appearance.read(Sys.getCwd());
		rayde.ui.Theming.apply(appearance); rayde.ui.Style.use();
		var failed:Null<String> = null;
		WindowedApp.run({title:"RayDE editor memory",width:1280,height:800,decorations:false,theme:rayde.ui.Theming.shown(appearance)}, () -> {
			var app = WindowedApp.current;
			function later(seconds:Float, work:Void->Void):Void AnimationScheduler.main.after(seconds, () -> {
				try work() catch (error:Dynamic) { failed = Std.string(error); Sys.stderr().writeString(failed + "\n"); app.quit(); }
			});
			function editor():Element {
				var result = <code-editor ref={ref} state={state} language={mode == "plain" ? "plain" : "haxe"} minimap={mode != "no-minimap"}
					lineNumbers={true} folding={true} gutterMarkers={true} indentGuides={true} highlightBrackets={true}
					tabSize={4} class="flex-1 min-h-0 min-w-0"/>;
				Owner.onCleanup(state.compact);
				return result;
			}
			var root = <div id="rayde" width={960} height={650} class="flex flex-col"><if {shown.get()}>${editor()}</if></div>;
			function sample(phase:String, next:Void->Void):Void {
				hl.Gc.major(); app.device.poll();
				later(2, () -> {
					var heap = hl.Gc.stats(), canvases = 0, vertices = 0, canvasCpu = 0, canvasGpu = 0;
					@:privateAccess for (canvas in ashui.ui.Canvas.bySlot) { canvases++; vertices+=canvas.painter.vertexCount;
						canvasGpu+=canvas.painter.rows*2048*16; if(canvas.painter.bytes!=null) canvasCpu+=canvas.painter.bytes.length;
						canvasCpu+=canvas.painter.mesh.data.length*8; }
					Sys.println("welcome-memory:"+haxe.Json.stringify({mode:phase,variant:mode,file:file,gcHeapBytes:heap.currentMemory,
						totalAllocatedBytes:heap.totalAllocated,nodes:app.tree.order().length,rows:Css.query(app.tree,root.node.id,".ui-code-line").length,
						tokens:Css.query(app.tree,root.node.id,".ui-code-token").length,canvases:canvases,canvasVertices:vertices,canvasCpuBytes:canvasCpu,canvasGpuBytes:canvasGpu}));
					Sys.stdout().flush();
					if (Sys.getEnv("MEMORY_PROBE_DUMP")=="1") hl.Gc.dumpMemory(ack+"."+phase+".heap");
					var deadline = haxe.Timer.stamp()+90;
					function wait():Void {
						if (sys.FileSystem.exists(ack)) {sys.FileSystem.deleteFile(ack);next();}
						else if (haxe.Timer.stamp()>deadline) throw "Sampler timeout";
						else later(.1,wait);
					}
					wait();
				});
			}
			later(3, () -> sample("baseline", () -> {
				shown.set(true);
				later(4, () -> sample("editor-open", () -> {
					shown.set(false);
					later(4, () -> sample("editor-hidden", app.quit));
				}));
			}));
			return root;
		});
		if (failed != null) throw failed;
	}
}
