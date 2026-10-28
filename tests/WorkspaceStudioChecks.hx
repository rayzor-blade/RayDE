import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.ext.Manifest;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

@:access(rayde.ui.Workbench)
@:access(rayde.ui.workbench.ExplorerPart)
@:access(rayde.ui.workbench.ExtensionsPart)
@:access(rayde.ui.workbench.ThemePart)
@:access(rayde.ui.workbench.DocumentsPart)
@:access(rayde.ui.workbench.CodeActionsPart)
class WorkspaceStudioChecks {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;
	static function main():Void {
		var root=Sys.getCwd()+"bin/workspace-studio-"+Std.random(0x3fffffff);
		for (dir in ["home","empty-extensions","src/plugin/ext"]) sys.FileSystem.createDirectory(root+"/"+dir);
		Sys.putEnv("HOME",root+"/home");Sys.putEnv("RAYDE_EXTENSIONS",root+"/empty-extensions");
		sys.io.File.saveContent(root+"/build.hxml","-cp src\n--interp\n");
		var file=root+"/src/plugin/ext/main.rays", config=root+"/src/plugin/plugin.rayext";
		sys.io.File.saveContent(file,'import rayde.settings.get; trace(await get("greeting", "fallback")); mount(() -> <div id="context-preview">Ready</div>);');
		sys.io.File.saveContent(config,'{"id":"context","main":"ext/main.rays","sources":["ext"],"styles":["view.css"],"views":[{"id":"main","title":"Context preview","location":"editor"}],"contributes":{"configuration":{"properties":{"greeting":{"type":"string","default":"configured"}}}}}');
		sys.io.File.saveContent(root+"/src/plugin/view.css",'#context-preview { color: #abcdef; }');
		sys.io.File.saveContent(root+"/src/plugin/ext/unrelated.rayext",'{"id":"wrong","main":"another.rays","capabilities":["workspace.write"]}');
		var helper=root+"/src/plugin/ext/helper.rays";
		sys.io.File.saveContent(helper,'function helper() return "module";');
		var module=Manifest.forSource(helper,root,() -> false);
		check(module!=null&&module.file==config,"Source module lost its declaring manifest");
		check(Manifest.forMain(helper,root,() -> false)==null,"Module lookup changed the entry-only contract");
		check(Manifest.forSource(helper,root+"/src/plugin/ext",() -> false)==null,"Module search crossed its workspace boundary");
		check(Manifest.forSource(helper,root,() -> true)==null,"Module search ignored cancellation");
		var found=Manifest.forMain(file,root,() -> false);
		check(found!=null&&found.file==config&&found.importRoot()==root+"/src/plugin/ext","Main script lost its ancestor manifest");
		check(Manifest.forMain(file,root+"/src/plugin/ext",() -> false)==null,"Manifest search crossed its workspace boundary");
		check(Manifest.forMain(file,root,() -> true)==null,"Manifest search ignored cancellation");
		var one=root+"/src/one.raytheme",two=root+"/src/two.raytheme";
		sys.io.File.saveContent(one,'{"id":"one","name":"First theme","colors":{"primary":"#8844cc"}}');
		sys.io.File.saveContent(two,'{"id":"two","name":"Second theme","colors":{"primary":"#44cc88"}}');
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),Dark);rayde.ui.Style.use();
		var compiler=new CompilerServer(),tree=new LayoutTree(),stop:Void->Void=null;
		var bench=Owner.root(tree,cleanup -> {stop=cleanup;return new Workbench({display:Display.ofProject(compiler,root+"/build.hxml"),name:"Studio workspace"});});
		function settle():Void {ashui.core.render.Offscreen.advance(.03);Css.setViewport(1280,800);Css.update();tree.flush();tree.computeLayout(bench.node,1280,800);}
		function until(done:Void->Bool,message:String):Void {var end=haxe.Timer.stamp()+8;while (!done()&&haxe.Timer.stamp()<end){settle();Sys.sleep(.005);}if (!done()) for (s in bench.extensionsPart.studios) Sys.println(s.file+" "+s.state.get()+" "+s.progress.get()+" "+haxe.Json.stringify(s.console.get()));check(done(),message);settle();}
		function click(selector:String):Void {var nodes=Css.query(tree,bench.node.id,selector);check(nodes.length==1,"Missing control "+selector);var b=tree.getScrolledBounds(new ashui.layout.Node(nodes[0]));ashui.input.Pointer.move(tree,b.x+b.width/2,b.y+b.height/2);ashui.input.Pointer.press(tree);ashui.input.Pointer.release(tree);settle();}
		try {
			bench.openFile(file);settle();
			check(bench.extensionsPart.studioFor(file)==null,"Opening source eagerly started its preview");
			var editors=Css.query(tree,bench.node.id,".rayde-code-editor");
			var before=tree.getBounds(new ashui.layout.Node(editors[0]));
			until(() -> Lambda.exists(bench.codeActionsPart.codeActions.list(), item -> item.action.kind == "preview"),"Source has no Preview code action");
			check(bench.extensionsPart.studioFor(file)==null,"Requesting code actions eagerly started its preview");
			click('.rayde-code-action[title="Preview Extension"]');until(() -> bench.extensionsPart.studioFor(file)!=null&&bench.extensionsPart.studioFor(file).hasView(),"Preview code action did not mount the Sheet");
			var studio=bench.extensionsPart.studioFor(file);
			var after=tree.getBounds(new ashui.layout.Node(Css.query(tree,bench.node.id,".rayde-code-editor")[0]));
			check(Math.abs(before.width-after.width)<.1 && Css.query(tree,bench.node.id,"#rayde-studio-columns").length==0,"Preview sheet resized the source editor");
			check(studio.manifest!=null&&studio.manifest.file==config,"Studio did not use the declaring manifest");
			check(Lambda.exists(studio.console.get(),e -> e.text=="configured"),"Manifest settings did not reach the script");
			var preview=Css.query(tree,bench.node.id,"#context-preview");
			check(preview.length==1&&Css.resolved(ashui.css.Identity.of(tree,preview[0]),"color")=="#abcdef","Late manifest styles did not attach to the preview");
			bench.closeFile(file);settle();
			check(bench.extensionsPart.studioFor(file)==null,"Closed source retained its development Studio");
			bench.openFile(helper);settle();
			bench.codeActionsPart.showCodeActions();
			until(() -> bench.centerRequest.get().picker.items.length == 1 && bench.centerRequest.get().picker.items[0].label == "Preview Extension","Code Actions chooser lost the module preview");
			bench.centerRequest.get().picker.items[0].run();bench.quickOpen.set(false);settle();
			until(() -> bench.extensionsPart.studioFor(helper)!=null&&bench.extensionsPart.studioFor(helper).hasView(),"Module code action did not preview its extension entry");
			var helperStudio=bench.extensionsPart.studioFor(helper);
			check(helperStudio.file==file&&helperStudio.manifest.file==config,"Helper preview ran the helper instead of its entry point");
			check(Lambda.exists(helperStudio.console.get(),e -> e.text=="configured"),"Helper preview lost manifest settings");
			bench.closeFile(helper);settle();
			check(bench.extensionsPart.studioFor(helper)==null,"Closed helper retained its development Studio");
			bench.explorerPart.openExplorerFile(one);settle();
			check(bench.active.get()==one&&Css.query(tree,bench.node.id,"#rayde-theme-studio").length==1,"Explorer did not open a workspace theme form");
			check(bench.themePart.themeStudio==null&&bench.explorerPart.headRow().path==root+"/build.hxml","Theme preview changed workspace identity");
			check(bench.sessionSnapshot().files.indexOf("src/one.raytheme")>=0,"Theme tab cannot be restored by file path");
			var model=bench.themePart.fileStudios.get(one);
			check(model.edit(t -> rayde.theme.ThemeEdit.setText(t,"name","Edited theme"))==null,"Theme form could not edit its file");settle();
			check(haxe.Json.parse(sys.io.File.getContent(one)).name=="Edited theme","Theme form did not save the same file");
			click("#rayde-theme-text");check(bench.editorOf(one)!=null,"Open as JSON did not mount the code editor");
			click("#rayde-theme-return");check(Css.query(tree,bench.node.id,"#rayde-theme-studio").length==1,"JSON editor cannot return to the form");
			bench.explorerPart.openExplorerFile(two);settle();
			check(rayde.ui.Theming.pinned.file==two,"Second theme did not become the preview");
			bench.closeFile(one);settle();check(rayde.ui.Theming.pinned.file==two,"Closing an inactive theme reset the active preview");
			bench.closeFile(two);settle();check(Lambda.count(bench.themePart.fileStudios)==0&&rayde.ui.Theming.pinned==null,"Closing theme tabs retained their models or preview");
		} catch(error:Dynamic) {stop();tree.dispose();compiler.stop();throw error;}
		stop();tree.dispose();compiler.stop();
		Sys.println("Workspace studios: ancestor manifest, settings, styles, theme Explorer/form/JSON/save, tab identity and cleanup passed");
	}
}
