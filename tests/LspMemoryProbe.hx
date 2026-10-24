import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.theme.ThemeState;
import ashui.theme.themes.RestrainedTheme;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.settings.Store;
import rayde.ui.Workbench;

/** Matched UI workloads; checkpoints pause for an external process-footprint sampler. */
class LspMemoryProbe {
	static function main():Void {
		var mode = Sys.getEnv("RAYDE_LSP_MODE") ?? "fixture";
		var root = Sys.getCwd() + "bin/lsp-memory-workspace-" + mode;
		sys.FileSystem.createDirectory(root + "/src");
		sys.FileSystem.createDirectory(root + "/builtins/rayzor/ext");
		for (name in ["rayzor.rayext", "logo.svg", "ext/main.rays"])
			sys.io.File.copy("extensions/rayzor/" + name, root + "/builtins/rayzor/" + name);
		sys.io.File.saveContent(root + "/build.hxml", "-cp src\n-main Main\n");
		var files = [root + "/src/Main.hx"], count = Std.parseInt(Sys.getEnv("RAYDE_LSP_FILES") ?? "10");
		for (i in 0...count) {
			var file = root + '/src/Sample$i.hx';
			sys.io.File.saveContent(file, 'class Sample$i {\n public function new() {}\n' + [for (j in 0...100) ' public var field$j:Int = $j;\n public function method$j():Int { return field$j; }\n'].join("") + "}\n");
			files.push(file);
		}
		var main = "class Main {\n static function main() {\n  var item = new Sample0();\n  trace(item.field0);\n }\n}\n";
		sys.io.File.saveContent(files[0], main);
		Sys.putEnv("RAYDE_EXTENSIONS", root + "/builtins");
		if (mode == "off") Store.save(root, "extensions", {disabled:["rayzor"]});
		else Store.save(root, "extensions", {disabled:[]});
		var command = Sys.getEnv("RAYDE_LSP_COMMAND") ?? Sys.getCwd() + "bin/rayzor";
		if (mode == "fixture") {
			command = root + "/fixture-server";
			sys.io.File.saveContent(command, "#!/usr/bin/env python3\nimport runpy, sys\nsys.argv = [" + haxe.Json.stringify(Sys.getCwd() + "tests/lsp_server_fixture.py") + ", " + haxe.Json.stringify(root + "/server-events") + "]\nrunpy.run_path(sys.argv[0], run_name='__main__')\n");
			Sys.command("chmod", ["+x", command]);
		}
		Store.save(root, "extension.rayzor", {command:command});
		ThemeState.init(RestrainedTheme.bundle(), Dark);
		rayde.ui.Style.use();
		var compiler = new CompilerServer(), tree = new LayoutTree(), stop:Void->Void = null;
		var bench:Workbench = Owner.root(tree, cleanup -> {
			stop = cleanup;
			return new Workbench({display:Display.ofHxml(compiler, root + "/build.hxml"), name:"LSP memory", runtime:"ash"});
		});
		var renderer = Snapshot.renderer(), texture = renderer.createTexture(1280, 800);
		var target = texture.createView(new gpu.GpuTextureViewDescriptor());
		var last = haxe.Timer.stamp();
		function frame():Void {
			var now = haxe.Timer.stamp(), elapsed = now-last; last=now;
			ashui.animation.AnimationScheduler.main.tick(Math.min(.1, elapsed), elapsed);
			ThemeState.get().tick(); Css.update(); tree.flush(); tree.computeLayout(bench.node,1280,800);
			renderer.renderTree(tree,bench.node,target,1280,800);
			ashui.core.Memory.afterFrame();
		}
		function drive(seconds:Float):Void {
			var until = haxe.Timer.stamp()+seconds;
			do { frame(); Sys.sleep(.008); } while(haxe.Timer.stamp()<until);
		}
		function ready():Void {
			var until = haxe.Timer.stamp()+30;
			while (mode!="off" && (bench.languagesPart.languageServers.client(files[0])==null || bench.languagesPart.languageServers.client(files[0]).state!="ready")) {
				frame(); Sys.sleep(.01);
				if(haxe.Timer.stamp()>until) throw "LSP did not initialize";
			}
		}
		var sequence = 0, completionPeakRows = 0;
		function emit(phase:String, allocated:Float=0., ms:Float=0.):Void {
			var retained=0, chars=0, pending=0, completionItems=0, completionRows=0, editors=0, watches=0;
			var client = bench.languagesPart.languageServers.client(files[0]);
			if (client!=null) {
				@:privateAccess for(doc in client.documents) { retained++; chars+=doc.text.length; }
				@:privateAccess for(_ in client.pending) pending++;
			}
			@:privateAccess for (watch in ashui.reactive.Watch.bySlot) if(watch!=null) watches++;
			@:privateAccess for(owner=>component in ashui.ui.Component.hosts) if(Type.getClassName(Type.getClass(component)) == "ashui.components.CodeEditor" && !owner.disposed) editors++;
			var editor=bench.editorFor(files[0]);
			if(editor!=null) {
				@:privateAccess completionItems=editor.completions.items.length;
				@:privateAccess completionRows=editor.completions.rows.get().length;
			}
			var ack = Sys.getEnv("RAYDE_LSP_ACK") + "/" + sequence++;
			Sys.println("lsp-memory:"+haxe.Json.stringify({mode:mode,phase:phase,ack:ack,allocated:allocated,ms:ms,heap:hl.Gc.stats(),
				nodes:tree.order().length,watches:watches,editors:editors,documents:retained,documentCharacters:chars,pending:pending,
				completionItems:completionItems,completionRows:completionRows,completionPeakRows:completionPeakRows,
				mountedCompletionRows:Css.query(tree,bench.node.id,".ui-code-completion-row").length,problemRows:Css.query(tree,bench.node.id,".rayde-problem").length})); Sys.stdout().flush();
			var deadline=haxe.Timer.stamp()+60;
			while(!sys.FileSystem.exists(ack)) { if(haxe.Timer.stamp()>deadline) throw "Sampler timeout"; Sys.sleep(.01); }
			sys.FileSystem.deleteFile(ack); last=haxe.Timer.stamp();
		}
		function phase(name:String, action:Void->Void):Void {
			var before=hl.Gc.stats().totalAllocated, start=haxe.Timer.stamp(); action();
			emit(name,hl.Gc.stats().totalAllocated-before,(haxe.Timer.stamp()-start)*1000);
		}
		drive(1); hl.Gc.major(); emit("empty-collected");
		phase("open-tabs", () -> { for(file in files) { bench.openFile(file); frame(); } bench.openFile(files[0]); ready(); drive(1); });
		hl.Gc.major(); emit("open-collected");
		phase("idle-3s", () -> drive(3));
		hl.Gc.major(); emit("idle-collected");
		if (Sys.getEnv("RAYDE_LSP_DIAGNOSTICS") == "1") {
			var diagnostics:Array<Dynamic> = [for(i in 0...200) {severity:1,message:'Diagnostic $i',range:{start:{line:0,character:0},end:{line:0,character:1}}}];
			function publish():Void bench.languagesPart.languageServers.onDiagnostics({uri:rayde.lang.LspProtocol.uri(files[0]),diagnostics:diagnostics});
			phase("diagnostics-hidden", () -> { publish(); drive(.5); });
			hl.Gc.major(); emit("diagnostics-hidden-collected");
			phase("diagnostics-repeat", () -> { publish(); drive(.5); });
			phase("diagnostics-shown", () -> { bench.showPanel("problems"); drive(.5); var id=Css.query(tree,bench.node.id,"#rayde-problems")[0]; ashui.input.Scroll.at(id,tree).scrollTo(0,240); drive(.1); });
			phase("diagnostics-close", () -> { bench.panelsPart.closePanel(); drive(.5); });
			hl.Gc.major(); emit("diagnostics-closed-collected");
			bench.showPanel("problems"); drive(.2);
			var restored = ashui.input.Scroll.at(Css.query(tree,bench.node.id,"#rayde-problems")[0],tree);
			if (Math.abs(restored.y.get()-240)>1) throw "Problems scroll offset was lost on remount";
			bench.panelsPart.closePanel(); drive(.2);
			phase("diagnostics-clear", () -> { bench.languagesPart.languageServers.onDiagnostics({uri:rayde.lang.LspProtocol.uri(files[0]),diagnostics:[]}); drive(.3); });
			bench.closeAll(); drive(.5); hl.Gc.major(); emit("closed-collected");
			stop(); compiler.stop(); tree.dispose(); target.destroy(); texture.destroy();
			return;
		}
		phase("poll-10000", () -> { for(_ in 0...10000) bench.languagesPart.languageServers.tick(); });
		phase("tab-switches", () -> { for(i in 0...30) { bench.openFile(files[i%files.length]); frame(); } bench.openFile(files[0]); drive(.3); });
		hl.Gc.major(); emit("switches-collected");
		phase("edits-30", () -> {
			for(i in 0...30) { bench.documentsPart.buffer(files[0]).set(main+'// edit $i\n'); bench.documentsPart.edited(files[0]); frame(); }
			drive(1);
		});
		hl.Gc.major(); emit("edits-collected");
		var editor=bench.editorFor(files[0]), caret=main.indexOf("item.field0")+"item.".length;
		editor.select(caret,caret); editor.focus();
		phase("completions-5", () -> {
			for(_ in 0...5) {
				bench.runCommand("suggest"); drive(.4);
				completionPeakRows = Std.int(Math.max(completionPeakRows, Css.query(tree,bench.node.id,".ui-code-completion-row").length));
				editor.hideCompletions(); drive(.15);
			}
		});
		hl.Gc.major(); emit("completions-collected");
		phase("hover-5", () -> {
			for(_ in 0...5) {
				var client=bench.languagesPart.languageServers.client(files[0]);
				if(client!=null) client.request("textDocument/hover",rayde.lang.LspProtocol.at(files[0],editor.value.get(),caret+2), result -> {
					if(result!=null) editor.showHint({from:caret,to:caret+4,renderDocs:() -> rayde.ui.HoverDocumentation.render(result.contents)},true);
				},files[0]+"#hover");
				drive(.4); editor.hideHint(); drive(.15);
			}
		});
		hl.Gc.major(); emit("hovers-collected");
		phase("close-tabs", () -> { editor=null; bench.documentsPart.buffer(files[0]).set(main); bench.documentsPart.edited(files[0]); bench.runPart.saveAll(); bench.closeAll(); drive(1); });
		hl.Gc.major(); emit("closed-collected");
		drive(3); hl.Gc.major(); emit("closed-idle-collected");
		stop(); compiler.stop(); tree.dispose(); target.destroy(); texture.destroy();
	}
}
