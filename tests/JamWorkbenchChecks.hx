import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

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
@:access(rayde.jam.JamSession)
class JamWorkbenchChecks {
	static function check(ok:Bool,message:String):Void { if (!ok) throw message; }
	static function main():Void {
		var home=Sys.getEnv("HOME"), extensions=Sys.getEnv("RAYDE_EXTENSIONS");
		try for (dark in [true,false]) run(dark) catch (error:Dynamic) {
			Sys.putEnv("HOME",home); Sys.putEnv("RAYDE_EXTENSIONS",extensions); throw error;
		}
		Sys.putEnv("HOME",home); Sys.putEnv("RAYDE_EXTENSIONS",extensions);
		Sys.println("Jam UI: explicit sharing, exact edit ranges, Unicode, author undo/redo, IME deferral, panel controls, opt-in viewport follow, local navigation, reconnect, inactive views, durable recovery, and owner cleanup in both themes");
	}
	static function run(dark:Bool):Void {
		var root=Sys.getCwd()+"bin/jam-ui-"+Std.random(0x3fffffff), source="hello 🦀\nsecond line\n"+[for (i in 0...120) "line "+i].join("\n")+"\n";
		for (dir in [root+"/home",root+"/extensions",root+"/host",root+"/guest"]) sys.FileSystem.createDirectory(dir);
		Sys.putEnv("HOME",root+"/home"); Sys.putEnv("RAYDE_EXTENSIONS",root+"/extensions");
		for (side in ["host","guest"]) {
			sys.io.File.saveContent(root+"/"+side+"/shared.txt",source);
			sys.io.File.saveContent(root+"/"+side+"/other.txt","other");
		}
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),dark ? Dark : Light); rayde.ui.Style.use();
		var ta=new LayoutTree(), tb=new LayoutTree(), ca=new CompilerServer(), cb=new CompilerServer(), sa:Void->Void=null, sb:Void->Void=null;
		var a=Owner.root(ta,clean -> { sa=clean; return new Workbench({display:new Display(ca,root+"/host",[]),name:"host"}); });
		var b=Owner.root(tb,clean -> { sb=clean; return new Workbench({display:new Display(cb,root+"/guest",[]),name:"guest"}); });
		var fa=root+"/host/shared.txt", fb=root+"/guest/shared.txt";
		function settle():Void {
			Offscreen.advance(.02); Css.setViewport(1100,760); Css.update();
			ta.flush(); tb.flush(); ta.computeLayout(a.node,1100,760); tb.computeLayout(b.node,1100,760);
		}
		function until(done:Void->Bool,why:String):Void {
			var end=haxe.Timer.stamp()+12;
			while (!done() && haxe.Timer.stamp()<end) { settle(); Sys.sleep(.005); }
			check(done(),why+"; host="+(rayde.jam.JamFeature.of(a.contributions).session.get()==null ? "none" : rayde.jam.JamFeature.of(a.contributions).session.get().failure.get())+"; guest="+(rayde.jam.JamFeature.of(b.contributions).session.get()==null ? "none" : rayde.jam.JamFeature.of(b.contributions).session.get().failure.get())); settle();
		}
		function click(bench:Workbench,tree:LayoutTree,selector:String):Void {
			settle();
			var nodes=Css.query(tree,bench.node.id,selector); check(nodes.length==1,"Missing control "+selector);
			var bounds=tree.getScrolledBounds(new ashui.layout.Node(nodes[0]));
			ashui.input.Pointer.move(tree,bounds.x+bounds.width/2,bounds.y+bounds.height/2); settle();
			ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); settle();
		}
		try {
			check(rayde.jam.JamFeature.of(a.contributions).session.get()==null && !rayde.jam.JamFeature.of(a.contributions).polling(),"Session-free window started Jam polling");
			click(a,ta,"#rayde-jam-status");
			check(a.sideView.get()=="jam" && Css.query(ta,a.node.id,"#rayde-jam-panel").length==1,"Idle joystick did not open the Jam panel");
			check(rayde.jam.JamFeature.of(a.contributions).session.get()==null && rayde.jam.JamFeature.of(b.contributions).session.get()==null && b.sideView.get()!="jam","Opening Jam started a session or affected another window");
			check(Css.query(ta,a.node.id,"#rayde-jam-start:disabled").length==1,"Welcome offered to share a nonexistent document");
			Snapshot.capture('jam-idle-${dark ? "dark" : "light"}',ta,a.node,1100,760);
			click(a,ta,"#rayde-jam-hide"); check(Css.query(ta,a.node.id,"#rayde-jam-panel").length==0,"Hidden Jam retained presentation");
			a.openFile(fa); b.openFile(fb); settle();
			for (id in ["jam.start","jam.join","jam.copy","jam.leave","jam.resume","jam.rejoin","jam.open","jam.stopFollowing"]) check(Lambda.exists(a.commandList,c -> c.id==id),"Missing command "+id);
			a.runCommand("jam.open"); settle(); click(a,ta,"#rayde-jam-start"); check(a.prompt.get()!=null && a.prompt.get().action=="Start Jam","Share command did not request explicit consent");
			a.prompt.get().accept("Host"); a.prompt.set(null);
			until(() -> rayde.jam.JamFeature.of(a.contributions).session.get().initialized.get() && rayde.jam.JamFeature.of(a.contributions).session.get().invite.get()!="","Host did not connect");
			b.runCommand("jam.open"); settle(); click(b,tb,"#rayde-jam-join"); check(b.prompt.get()!=null,"Join command did not request an invitation");
			var user=Sys.getEnv("USER"); Sys.putEnv("USER",StringTools.rpad("Guest ","W",64));
			b.prompt.get().accept(rayde.jam.JamFeature.of(a.contributions).session.get().invite.get()); b.prompt.set(null); Sys.putEnv("USER",user);
			until(() -> rayde.jam.JamFeature.of(b.contributions).session.get().initialized.get() && rayde.jam.JamFeature.of(a.contributions).session.get().people.get().length==2,"Guest did not connect");
			var ja=rayde.jam.JamFeature.of(a.contributions).session.get(), jb=rayde.jam.JamFeature.of(b.contributions).session.get(), guestSerial=jb.serial;
			var ea=a.editorFor(fa), eb=b.editorFor(fb);
			until(() -> ja.positionOf(jb.peer)!=null && jb.positionOf(ja.peer)!=null,"Initial participant presence did not arrive");
			for (_ in 0...24) { eb.scroll.jumpTo(0,eb.scroll.y.get()+15); settle(); Sys.sleep(.005); }
			check(ja.positionOf(jb.peer).view!=null && ja.positionOf(jb.peer).view.top>0,"Continuous scroll presence waited until movement stopped");
			var previousPresence=jb.positionOf(ja.peer).caret;
			var target=source.indexOf("line 70"); eb.select(target,target+4); settle(); eb.scroll.jumpTo(0,1000);
			until(() -> ja.positionOf(jb.peer).view!=null && ja.positionOf(jb.peer).view.top>0,"Viewport-only presence did not arrive");
			var focusBefore=ashui.input.Focus.of(ta); rayde.jam.JamFeature.of(a.contributions).followJam(jb.peer);
			until(() -> ea.editing.caret.get()==eb.editing.caret.get() && Math.abs(ea.scroll.y.get()-eb.scroll.y.get())<2,"Follow did not match caret and viewport");
			check(ashui.input.Focus.of(ta)==focusBefore,"Following stole keyboard focus");
			check(ja.following.get()==jb.peer && !ja.isSelf(jb.peer),"Follow did not select the intended participant");
			for (_ in 0...10) settle();
			check(jb.positionOf(ja.peer).caret==previousPresence,"Following echoed another participant's caret as local presence");
			Snapshot.capture('jam-follow-${dark ? "dark" : "light"}',ta,a.node,1100,760);
			Css.setViewport(720,480); ta.flush(); ta.computeLayout(a.node,720,480);
			Snapshot.capture('jam-small-${dark ? "dark" : "light"}',ta,a.node,720,480); settle();
			click(a,ta,"#rayde-jam-hide");
			check(ja.following.get()==jb.peer && ja.status.get()=="connected" && Css.query(ta,a.node.id,"#rayde-jam-panel").length==0,"Hiding the panel ended follow or the session");
			rayde.jam.JamFeature.of(a.contributions).showJam(); settle();
			ea.focus(); ashui.input.Keyboard.input(ta,window.KeyEvent.Input(Unidentified(Unidentified),Named(ArrowLeft),None,Standard,Pressed,false,Unavailable)); settle();
			check(ja.following.get()=="","Keyboard navigation did not stop following");
			click(a,ta,"#rayde-jam-follow-"+jb.peer); check(ja.following.get()==jb.peer,"Follow button did not select the participant");
			var bounds=ta.getScrolledBounds(ea.scroll.node);
			ashui.input.Pointer.move(ta,bounds.x+bounds.width/2,bounds.y+bounds.height/2); ashui.input.Pointer.wheel(ta,0,40); settle();
			check(ja.following.get()=="","Wheel navigation did not stop following");
			rayde.jam.JamFeature.of(a.contributions).followJam(jb.peer); settle();
			ashui.input.Pointer.press(ta); ashui.input.Pointer.release(ta); settle();
			check(ja.following.get()=="","Pointer navigation did not stop following");
			rayde.jam.JamFeature.of(a.contributions).followJam(jb.peer); a.openFile(root+"/host/other.txt"); settle();
			check(ja.following.get()=="","Changing tabs did not stop following"); a.openFile(fa); settle(); ea=a.editorFor(fa);
			rayde.jam.JamFeature.of(a.contributions).followJam(jb.peer); settle(); jb.pause(true);
			until(() -> ja.following.get()=="" && jb.status.get()=="paused","Disconnect or participant departure did not stop following");
			jb.pause(false); until(() -> jb.status.get()=="connected" && ja.people.get().length==2,"Participant did not reconnect");
			ea.select(0,0); eb.select(0,0); ea.scroll.jumpTo(0,0); eb.scroll.jumpTo(0,0); settle(); guestSerial=jb.serial;
			rayde.jam.JamFeature.of(a.contributions).followJam(jb.peer); settle();
			ea.applyEdits([{from:0,to:0,text:"A: "},{from:8,to:8,text:"!"}]);
			check(ja.following.get()=="","Editing did not stop following");
			until(() -> b.documentsPart.buffer(fb).get()==a.documentsPart.buffer(fa).get(),"Exact multi-range edits did not arrive");
			check(jb.serial==guestSerial,"Remote apply echoed as a local transaction");
			ea.undo(); until(() -> a.documentsPart.buffer(fa).get()==source && b.documentsPart.buffer(fb).get()==source,"Multi-range action did not undo together");
			ea.select(8,8); ea.editing.replace(" A");
			until(() -> b.documentsPart.buffer(fb).get()==a.documentsPart.buffer(fa).get(),"Typed edit did not arrive");
			eb.select(0,0); eb.editing.replace("B: ");
			until(() -> a.documentsPart.buffer(fa).get()==b.documentsPart.buffer(fb).get(),"Guest edit did not arrive");
			ea.undo(); until(() -> a.documentsPart.buffer(fa).get()=="B: "+source && b.documentsPart.buffer(fb).get()==a.documentsPart.buffer(fa).get(),"Author undo removed another participant's edit");
			ea.redo(); until(() -> b.documentsPart.buffer(fb).get()==a.documentsPart.buffer(fa).get(),"Author redo did not arrive");
			eb.select(1,1); ea.applyEdits([{from:0,to:0,text:"Z"}]);
			until(() -> b.documentsPart.buffer(fb).get()==a.documentsPart.buffer(fa).get(),"Remote edit did not arrive after moving the local caret");
			check(eb.editing.caret.get()==2,"Throttled presence moved the local caret back to its previous location");
			ea.undo(); until(() -> b.documentsPart.buffer(fb).get()==a.documentsPart.buffer(fa).get(),"Caret fixture did not undo");
			eb.select(0,3); jb.moved(3,0);
			until(() -> Lambda.exists(a.documentsPart.documentState(fa).peers.get(),p -> p.caret==3 && p.anchor==0),"Remote selection did not arrive");
			check(Css.query(ta,a.node.id,".ui-code-peer-caret").length==1 && Css.query(ta,a.node.id,".ui-code-peer-selection").length>=1,"Remote caret or selection was not rendered: caret="+Css.query(ta,a.node.id,".ui-code-peer-caret").length+", selection="+Css.query(ta,a.node.id,".ui-code-peer-selection").length+", marks="+haxe.Json.stringify(a.documentsPart.documentState(fa).peers.get()));
			Snapshot.capture('jam-${dark ? "dark" : "light"}',ta,a.node,1100,760);
			var before=b.documentsPart.buffer(fb).get(); eb.editing.composing.set("文"); settle();
			ea.applyEdits([{from:0,to:0,text:"remote "}]);
			for (_ in 0...8) { settle(); Sys.sleep(.01); }
			check(b.documentsPart.buffer(fb).get()==before,"Remote update disturbed an active IME composition");
			eb.editing.composing.set(""); until(() -> b.documentsPart.buffer(fb).get()==a.documentsPart.buffer(fa).get(),"Deferred update did not arrive after composition");
			jb.pause(true); until(() -> jb.status.get()=="paused","Pause did not disconnect");
			eb.applyEdits([{from:0,to:0,text:"offline "}]);
			jb.pause(false); until(() -> jb.status.get()=="connected" && b.documentsPart.buffer(fb).get()==a.documentsPart.buffer(fa).get(),"Offline edits did not reconcile");
			var state=a.documentsPart.documentState(fa); a.openFile(root+"/host/other.txt"); settle();
			check(!state.mounted,"Inactive shared document retained its editor");
			eb.applyEdits([{from:0,to:0,text:"hidden "}]); until(() -> b.documentsPart.buffer(fb).get()==a.documentsPart.buffer(fa).get(),"Inactive document stopped synchronizing");
			a.openFile(fa); settle(); check(a.editorFor(fa).value.get()==b.documentsPart.buffer(fb).get(),"Reopened editor lost the shared document");
			until(() -> ja.recoveryStatus.get()=="saved locally" && jb.recoveryStatus.get()=="saved locally","Edits were not checkpointed");
			var finalText=a.documentsPart.buffer(fa).get(), firstInvite=ja.invite.get();
			a.runCommand("jam.leave");
			until(() -> jb.failure.get()!="","Host closure was not reported to the guest");
			b.runCommand("jam.leave"); settle();
			check(ja.closed && jb.closed && ja.document==-1 && jb.transport==-1,"Leaving retained native handles");
			check(state.onUndo==null && state.onTransaction==null && state.peers.get().length==0,"Leaving retained document callbacks or peer decorations");
			check(Css.query(ta,a.node.id,".ui-code-peer-caret").length==0 && !rayde.jam.JamFeature.of(a.contributions).polling() && !rayde.jam.JamFeature.of(b.contributions).polling(),"Leaving retained views or polling");
			check(sys.io.File.getContent(fa)==source && sys.io.File.getContent(fb)==source,"Jam wrote files without Save");
			// Recovery replaces only a clean buffer and never needs an active old presentation.
			a.runCommand("jam.resume"); settle(); check(a.prompt.get()==null,"Recovery offered to replace unsaved editor changes");
			a.documentsPart.documentState(fa).value.set(source); b.documentsPart.documentState(fb).value.set(source); a.runPart.saveAll(); b.runPart.saveAll(); settle();
			a.editorFor(fa).select(source.length,source.length);
			a.runCommand("jam.resume"); settle(); check(a.prompt.get()!=null && a.prompt.get().action=="Resume Jam","Resume command did not request explicit consent");
			a.prompt.get().accept(""); a.prompt.set(null);
			until(() -> rayde.jam.JamFeature.of(a.contributions).session.get().status.get()=="connected","Host did not resume");
			check(a.documentsPart.buffer(fa).get()==finalText && rayde.jam.JamFeature.of(a.contributions).session.get().invite.get()!=firstInvite,"Resume reseeded text or reused an invitation");
			b.runCommand("jam.rejoin"); settle(); check(b.prompt.get()!=null,"Rejoin did not request an invitation");
			b.prompt.get().accept(rayde.jam.JamFeature.of(a.contributions).session.get().invite.get()); b.prompt.set(null);
			until(() -> rayde.jam.JamFeature.of(b.contributions).session.get().status.get()=="connected" && rayde.jam.JamFeature.of(a.contributions).session.get().people.get().length==2,"Guest did not restore and rejoin");
			check(b.documentsPart.buffer(fb).get()==finalText,"Restored peers diverged");
			rayde.jam.JamFeature.of(a.contributions).session.get().checkpoint(); until(() -> rayde.jam.JamFeature.of(a.contributions).session.get().recoveryStatus.get()=="saved locally","Explicit checkpoint failed");
			a.runCommand("jam.leave"); b.runCommand("jam.leave"); settle();
			check(sys.io.File.getContent(fa)==source && sys.io.File.getContent(fb)==source,"Jam wrote files without Save");
			for (_ in 0...10) { settle(); Sys.sleep(.005); }
			rayde.jam.JamFeature.of(a.contributions).begin(fa,true,"Room A",""); rayde.jam.JamFeature.of(b.contributions).begin(fb,true,"Room B","");
			until(() -> rayde.jam.JamFeature.of(a.contributions).session.get().status.get()=="connected" && rayde.jam.JamFeature.of(b.contributions).session.get().status.get()=="connected","Independent rooms did not connect");
			check(rayde.jam.JamFeature.of(a.contributions).session.get().invite.get()!=rayde.jam.JamFeature.of(b.contributions).session.get().invite.get() && rayde.jam.JamFeature.of(a.contributions).session.get().people.get().length==1 && rayde.jam.JamFeature.of(b.contributions).session.get().people.get().length==1,"Windows shared a room unexpectedly");
			var otherRoom=b.documentsPart.buffer(fb).get();
			a.editorFor(fa).applyEdits([{from:0,to:0,text:"isolated "}]);
			until(() -> rayde.jam.JamFeature.of(a.contributions).session.get().synced.get(),"Independent room edit was not acknowledged");
			check(b.documentsPart.buffer(fb).get()==otherRoom && rayde.jam.JamFeature.of(b.contributions).session.get().following.get()=="","One room changed another window's document or follow state");
			click(a,ta,"#rayde-jam-hide"); rayde.jam.JamFeature.of(a.contributions).leaveJam(); settle();
			check(rayde.jam.JamFeature.of(b.contributions).session.get().status.get()=="connected" && Css.query(tb,b.node.id,"#rayde-jam-panel").length==1,"Closing one room affected another window");
			rayde.jam.JamFeature.of(b.contributions).leaveJam(); settle();
			check(sys.io.File.getContent(fa)==source && sys.io.File.getContent(fb)==source,"Independent rooms wrote source files");

		} catch (error:Dynamic) { sa(); sb(); ta.dispose(); tb.dispose(); ca.stop(); cb.stop(); throw error; }
		sa(); sb(); ta.dispose(); tb.dispose(); ca.stop(); cb.stop();
	}
}
