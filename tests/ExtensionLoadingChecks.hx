import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

@:access(rayde.ui.workbench.ExtensionsPart)
@:access(rayde.ui.workbench.ShellPart)
@:access(rayde.ui.workbench.PanelsPart)
class ExtensionLoadingChecks {
	static function check(value:Bool,message:String):Void { if (!value) throw message; }
	public static function main():Void {
		var home=Sys.getEnv("HOME"), extensions=Sys.getEnv("RAYDE_EXTENSIONS");
		try for (dark in [false,true]) run(dark) catch (error:Dynamic) {
			Sys.putEnv("HOME",home); Sys.putEnv("RAYDE_EXTENSIONS",extensions); throw error;
		}
		Sys.putEnv("HOME",home); Sys.putEnv("RAYDE_EXTENSIONS",extensions);
		Sys.println("Extension loading: startup, delayed command registration and view mounting, stopped/failed feedback, retry, and cleanup passed in both themes");
	}
	static function run(dark:Bool):Void {
		var root=Sys.getCwd()+"bin/readiness-"+Std.random(0x3fffffff);
		for (directory in [root+"/home",root+"/extensions/delay/ext",root+"/workspace"]) sys.FileSystem.createDirectory(directory);
		Sys.putEnv("HOME",root+"/home"); Sys.putEnv("RAYDE_EXTENSIONS",root+"/extensions");
		var source=root+"/extensions/delay/ext/main.rays";
		var good='await sleep(700); registerCommand("late", () -> trace("ready")); mount(() -> <div id="delayed-ready" class="p-4"><text>Ready view</text></div>, "main"); onTool("refresh", () -> trace("refreshed"));';
		sys.io.File.saveContent(source,good);
		sys.io.File.saveContent(root+"/extensions/delay/delay.rayext",haxe.Json.stringify({id:"delay",name:"Delayed extension",main:"ext/main.rays",sources:["ext"],activationEvents:["onView:main","onCommand:late"],contributes:{commands:[{id:"late",title:"Delayed command"}]},views:[{id:"main",title:"Delayed view",location:"sidebar",tools:[{id:"refresh",title:"Refresh",icon:"refresh"}]}]}));
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),dark ? Dark : Light); rayde.ui.Style.use();
		var tree=new LayoutTree(), compiler=new CompilerServer(), clean:Void->Void=null;
		var bench=Owner.root(tree,dispose -> {clean=dispose;return new Workbench({display:new Display(compiler,root+"/workspace",[]),name:"Readiness"});});
		function settle():Void { Offscreen.advance(.02); Css.setViewport(1000,720); Css.update(); tree.flush(); tree.computeLayout(bench.node,1000,720); }
		function count(selector:String):Int return Css.query(tree,bench.node.id,selector).length;
		function until(done:Void->Bool,message:String):Void {
			var end=haxe.Timer.stamp()+8;
			while (!done() && haxe.Timer.stamp()<end) {settle();Sys.sleep(.005);}
			check(done(),message);settle();
		}
		try {
			settle();
			check(count("#rayde-extensions-loading")==0,"Inactive extensions showed an endless loading indicator");
			var container=Lambda.find(bench.extensionsPart.containers,c -> c.extension.id == "delay");
			check(container!=null,"Missing delayed extension view");
			bench.shellPart.chooseContainer(container); bench.runCommand("ext.delay.late"); settle();
			var entry=bench.extensionsPart.extensionManager.find("delay"), studio=bench.extensionsPart.studios.get(entry.connection.file);
			check(count("#rayde-extensions-loading")==1,"Extension activation and queued command had no status feedback");
			check(count("#rayde-studio-loading .ui-spinner")==1,"Empty activating extension view had no loading feedback");
			check(count("#rayde-tool-refresh:disabled")==1,"Unready view tool accepted input");
			Snapshot.capture('extension-loading-${dark ? "dark" : "light"}',tree,bench.node,1000,720);
			until(() -> studio.hasView("main") && studio.progress.get()=="","Delayed view or command never became ready");
			check(count("#rayde-extensions-loading")==0 && count("#rayde-studio-loading")==0,"Readiness feedback remained after content mounted");
			check(count("#rayde-tool-refresh:disabled")==0,"Ready view tool stayed disabled");
			var model=studio.preview, revision=studio.elements.get();
			for (cycle in 0...3) {
				bench.shellPart.chooseContainer(container); settle();
				check(!studio.hasView("main") && count("#delayed-ready")==0,"Closing the sidebar retained its mounted view");
				bench.shellPart.chooseContainer(container);
				for (_ in 0...3) settle();
				check(studio.hasView("main") && count("#delayed-ready")==1,"Reopening did not restore the retained view");
				check(count("#rayde-studio-loading")==0 && count("#rayde-tool-refresh:disabled")==0,"Reopening a ready sidebar kept its loading overlay or disabled tools");
				check(studio.preview==model && studio.elements.get()==revision,"Reopening needed a fresh extension render or replaced its model");
			}
			Snapshot.capture('extension-loading-reopened-${dark ? "dark" : "light"}',tree,bench.node,1000,720);
			studio.command("missing",null); settle();
			check(count("#rayde-extensions-loading")==1,"A command waiting for registration had no feedback");
			studio.stop(); settle();
			check(studio.progress.get()=="" && count("#rayde-extensions-loading")==0,"Stopping retained preparation feedback");
			check(count("#rayde-studio-loading .ui-spinner")==0 && count("#rayde-studio-loading-output")==1,"Stopped view looked like an endless load");
			check(count("#rayde-tool-refresh:disabled")==1,"Stopped extension tools remained enabled");
			studio.clearView(); sys.io.File.saveContent(source,"var = broken;"); studio.reload();
			until(() -> studio.failure.get()!="","Invalid extension did not report failure");
			check(count("#rayde-studio-loading-output")==1 && count("#rayde-studio-loading .ui-spinner")==0 && count("#rayde-extensions-loading")==0,"Failed startup kept spinning or provided no Output action");
			Snapshot.capture('extension-loading-error-${dark ? "dark" : "light"}',tree,bench.node,1000,720);
			var output=Css.query(tree,bench.node.id,"#rayde-studio-loading-output"), bounds=tree.getScrolledBounds(new ashui.layout.Node(output[0]));
			ashui.input.Pointer.move(tree,bounds.x+bounds.width/2,bounds.y+bounds.height/2); ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); settle();
			check(bench.panelsPart.bottom.get()=="console" && bench.extensionsPart.outputChannel.get()=="ext:delay","Failure feedback did not open the extension's Output channel");
			sys.io.File.saveContent(source,good); studio.reload(); settle();
			check(studio.failure.get()=="" && count("#rayde-extensions-loading")==1,"Retry retained a stale failure or hid preparation");
			until(() -> studio.hasView("main") && studio.progress.get()=="","Retry did not restore the view");
			// Command-only extensions can be inspected without promising a view that they never declare.
			var config=root+"/commands.rayext";
			sys.io.File.saveContent(config,haxe.Json.stringify({name:"Commands only",main:"commands.rays",views:[]}));
			sys.io.File.saveContent(root+"/commands.rays",'registerCommand("ready", () -> trace("ready"));');
			var detached=new LayoutTree(), release:Void->Void=null;
			var commands=new rayde.ext.Studio(root+"/commands.rays",() -> sys.io.File.getContent(root+"/commands.rays"),detached,rayde.ext.Manifest.read(config));
			var inspected=Owner.root(detached,dispose -> {release=dispose;return new rayde.ui.StudioView({studio:commands,onMocks:() -> {},onConsole:() -> {}});});
			commands.reload();
			until(() -> {commands.tick();return !commands.connection.starting;},"Command-only extension did not start");
			detached.flush();detached.computeLayout(inspected.node,320,400);
			check(commands.loadingMessage()=="" && Css.query(detached,inspected.node.id,"#rayde-studio-loading .ui-spinner").length==0,"Command-only extension kept an idle spinner alive");
			release();commands.dispose();detached.dispose();
			studio.reload(); settle(); clean(); clean=null;
			check(entry.connection.progress()=="" && !entry.connection.running(),"Closing during startup retained preparation or its host");
		} catch (error:Dynamic) {if (clean!=null) clean();tree.dispose();compiler.stop();throw error;}
		if (clean!=null) clean();tree.dispose();compiler.stop();
	}
}
