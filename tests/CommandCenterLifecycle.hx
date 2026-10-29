import ashui.css.Css;
import ashui.css.Identity;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import rayde.ui.CommandCenter;
import rayde.ui.CommandCenter.CenterRequest;

/** Large catalogs own no command rows while closed, including detached floating panels. */
class CommandCenterLifecycle {
	public static function main() {
		for (dark in [true, false]) run(dark);
	}

	static function run(dark:Bool) {
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light);
		rayde.ui.Style.use();
		var tree = new LayoutTree(), stop:Void->Void = null;
		var opened = Signal.make(false), request = Signal.make(({text:"", serial:0}:CenterRequest));
		var paths = Signal.make([for (i in 0...429) '/fixture/src/File$i.hx']), limited = Signal.make(false);
		var scans = 0, chosen = "", line = 0, center:CommandCenter = null;
		var root = Owner.root(tree, cleanup -> {
			stop = cleanup;
			var anchor = new ashui.ui.Div({width:400,height:36},[new ashui.ui.Text("Fixture project")]);
			center = new CommandCenter({opened:opened,request:request,anchor:anchor,root:"/fixture",
				files:() -> { scans++; return paths.get(); },
				filesLimited:() -> limited.get(),
				actions:[{id:"test",label:"Test action",icon:rayde.ui.Icons.HAXE,run:() -> chosen="action"}],
				tasks:() -> [{id:"task",label:"Build fixture",icon:rayde.ui.Icons.HAXE,run:() -> chosen="task"}],
				onOpenFile:path -> chosen=path,onLine:value -> line=value});
			return <div id="rayde" width={800} height={500} class="bg-background text-text-primary">${anchor}${center}</div>;
		});
		function settle(frames=30) for (_ in 0...frames) {
			ashui.core.render.Offscreen.advance(1/60); Css.update(); tree.flush(); tree.computeLayout(root.node,800,500);
		}
		function press(key:window.Key):Void {
			for (state in [window.MouseElementState.Pressed, window.MouseElementState.Released])
				ashui.input.Keyboard.input(tree, window.KeyEvent.Input(Unidentified(Unidentified), key, None, Standard, state, false, Unavailable));
		}
		function identities():Int return [for (_ in (@:privateAccess Identity.trees.get(tree))) 1].length;
		function rows():Int return [for (id in (@:privateAccess Identity.trees.get(tree))) if (id.id!=null && StringTools.startsWith(id.id,"center-")) 1].length;
		function texts():Int return [for (_ in (@:privateAccess ashui.ui.Text.byNode)) 1].length;
		function check(what:String,ok:Bool) { if (!ok) throw what; }
		function input():ashui.ui.Input {
			var panel = @:privateAccess center.panel;
			return ashui.ui.Input.at(tree,Css.query(tree,panel.node.id,"#rayde-command-input")[0]);
		}
		function open(text:String) { request.set({text:text,serial:request.get().serial+1}); opened.set(true); settle(); }
		settle();
		var base=identities(), baseTexts=texts(), hooks=ashui.input.Pointer.hooks.length;
		check("closed palette enumerated files or built rows",scans==0 && rows()==0);
		open(""); check("open palette did not bound its mounted catalog",rows()<=13 && rows()>0 && scans==1);
		limited.set(true); settle();
		check("truncated catalog has no feedback",Css.query(tree,(@:privateAccess center.panel).node.id,"#rayde-command-file-limit").length==1);
		ashui.core.render.Snapshot.capture('palette-${dark ? "dark" : "light"}-limited',tree,root.node,800,500);
		limited.set(false); settle();
		check("completed catalog retained truncation feedback",Css.query(tree,(@:privateAccess center.panel).node.id,"#rayde-command-file-limit").length==0);
		input().value.set("File428"); settle();
		check("search omitted an unmounted file",rows()==1 && Css.query(tree,(@:privateAccess center.panel).node.id,"#center-file-src-File428-hx").length==1);
		input().value.set("no such file"); settle();
		check("unmatched query retained rows", rows()==0);
		input().value.set(""); settle();
		press(window.Key.Named(End)); settle();
		check("End did not reveal the last virtual row", Css.query(tree,(@:privateAccess center.panel).node.id,"#center-file-src-File428-hx[data-selected]").length==1);
		press(window.Key.Named(Enter)); settle();
		check("Enter did not choose the last virtual row",!opened.get() && chosen=="/fixture/src/File428.hx");
		open("");
		var openCount=identities();
		ashui.core.render.Snapshot.capture('palette-${dark ? "dark" : "light"}-open',tree,root.node,800,500);
		input().value.set(">Test"); settle();
		check("typed command prefix lost its filter",rows()==1 && input().value.get()==">Test");
		input().value.set("task Build"); settle();
		check("task mode lost its filter",rows()==1 && input().value.get()=="task Build");
		input().value.set(":12"); settle();
		check("line mode did not release rows",rows()==0 && input().value.get()==":12");
		@:privateAccess center.goToLine(); settle();
		check("line navigation failed",!opened.get() && line==12);
		check("close retained nodes, text or pointer hooks",rows()==0 && identities()==base && texts()==baseTexts && ashui.input.Pointer.hooks.length==hooks);
		for (_ in 0...3) {
			open(">"); @:privateAccess center.choose("action:test"); settle();
			check("command action was lost",chosen=="action");
			open(""); opened.set(false); settle();
			check("repeated opens retained rows or text",identities()==base && texts()==baseTexts && rows()==0);
		}
		open(""); input().value.set("AddedLater"); settle();
		check("pending catalog query should have no results",rows()==0);
		paths.set(paths.get().concat(["/fixture/src/AddedLater.hx"])); settle();
		check("catalog completion reset the filter or input focus",rows()==1 && input().value.get()=="AddedLater" && ashui.input.Focus.of(tree).node.id==input().node.id);
		paths.set(paths.get().concat(["/fixture/README.md"])); input().value.set("README"); settle();
		var icons=Css.query(tree,(@:privateAccess center.panel).node.id,"#center-file-README-md .ui-icon");
		check("Markdown row did not render its file icon",icons.length==1);
		var svg = @:privateAccess ashui.ui.Svg.intrinsic.get(Identity.of(tree,icons[0]));
		check("Markdown row uses the wrong file icon",svg != null && svg.document==rayde.ui.FileIcons.of("README.md"));
		opened.set(false); settle();
		open(""); opened.set(false); settle(2); opened.set(true); settle();
		check("rapid reopen lost focus or rows",rows()<=13 && rows()>0 && ashui.input.Focus.of(tree).node.id==input().node.id);
		opened.set(false); settle();
		ashui.core.render.Snapshot.capture('palette-${dark ? "dark" : "light"}-closed',tree,root.node,800,500);
		Sys.println('[palette] ${dark ? "dark" : "light"}: closed rows=${rows()}, catalog=429, styled closed=$base, styled open=$openCount, final=${identities()}');
		stop(); tree.dispose();
	}
}
