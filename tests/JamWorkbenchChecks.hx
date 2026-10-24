import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.lang.Display;
import rayde.ui.Workbench;

@:access(rayde.ui.Workbench)
@:access(rayde.jam.JamSession)
class JamWorkbenchChecks {
	static function check(ok:Bool,message:String):Void { if (!ok) throw message; }
	static function main():Void {
		var home=Sys.getEnv("HOME"), extensions=Sys.getEnv("RAYDE_EXTENSIONS");
		try for (dark in [true,false]) run(dark) catch (error:Dynamic) {
			Sys.putEnv("HOME",home); Sys.putEnv("RAYDE_EXTENSIONS",extensions); throw error;
		}
		Sys.putEnv("HOME",home); Sys.putEnv("RAYDE_EXTENSIONS",extensions);
		Sys.println("Jam UI: explicit sharing, exact edit ranges, Unicode, author undo/redo, IME deferral, reconnect, inactive views, durable recovery, and owner cleanup in both themes");
	}
	static function run(dark:Bool):Void {
		var root=Sys.getCwd()+"bin/jam-ui-"+Std.random(0x3fffffff), source="hello 🦀\nsecond line\n";
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
			check(done(),why+"; host="+(a.jam.get()==null ? "none" : a.jam.get().failure.get())+"; guest="+(b.jam.get()==null ? "none" : b.jam.get().failure.get())); settle();
		}
		try {
			check(a.jam.get()==null && a.jamPoll==null,"Session-free window started Jam polling");
			a.openFile(fa); b.openFile(fb); settle();
			for (id in ["jam.start","jam.join","jam.copy","jam.leave","jam.resume","jam.rejoin"]) check(Lambda.exists(a.commandList,c -> c.id==id),"Missing command "+id);
			a.runCommand("jam.start"); settle(); check(a.prompt.get()!=null && a.prompt.get().action=="Start Jam","Share command did not request explicit consent");
			a.prompt.get().accept("Host"); a.prompt.set(null);
			until(() -> a.jam.get().initialized.get() && a.jam.get().invite.get()!="","Host did not connect");
			b.runCommand("jam.join"); settle(); check(b.prompt.get()!=null,"Join command did not request an invitation");
			b.prompt.get().accept(a.jam.get().invite.get()); b.prompt.set(null);
			until(() -> b.jam.get().initialized.get() && a.jam.get().people.get().length==2,"Guest did not connect");
			var ja=a.jam.get(), jb=b.jam.get(), guestSerial=jb.serial;
			var ea=a.editorFor(fa), eb=b.editorFor(fb);
			ea.applyEdits([{from:0,to:0,text:"A: "},{from:8,to:8,text:"!"}]);
			until(() -> b.buffer(fb).get()==a.buffer(fa).get(),"Exact multi-range edits did not arrive");
			check(jb.serial==guestSerial,"Remote apply echoed as a local transaction");
			ea.undo(); until(() -> a.buffer(fa).get()==source && b.buffer(fb).get()==source,"Multi-range action did not undo together");
			ea.select(8,8); ea.editing.replace(" A");
			until(() -> b.buffer(fb).get()==a.buffer(fa).get(),"Typed edit did not arrive");
			eb.select(0,0); eb.editing.replace("B: ");
			until(() -> a.buffer(fa).get()==b.buffer(fb).get(),"Guest edit did not arrive");
			ea.undo(); until(() -> a.buffer(fa).get()=="B: "+source && b.buffer(fb).get()==a.buffer(fa).get(),"Author undo removed another participant's edit");
			ea.redo(); until(() -> b.buffer(fb).get()==a.buffer(fa).get(),"Author redo did not arrive");
			eb.select(1,1); ea.applyEdits([{from:0,to:0,text:"Z"}]);
			until(() -> b.buffer(fb).get()==a.buffer(fa).get(),"Remote edit did not arrive after moving the local caret");
			check(eb.editing.caret.get()==2,"Throttled presence moved the local caret back to its previous location");
			ea.undo(); until(() -> b.buffer(fb).get()==a.buffer(fa).get(),"Caret fixture did not undo");
			eb.select(0,3); jb.moved(3,0);
			until(() -> Lambda.exists(a.documentState(fa).peers.get(),p -> p.caret==3 && p.anchor==0),"Remote selection did not arrive");
			check(Css.query(ta,a.node.id,".ui-code-peer-caret").length==1 && Css.query(ta,a.node.id,".ui-code-peer-selection").length>=1,"Remote caret or selection was not rendered: caret="+Css.query(ta,a.node.id,".ui-code-peer-caret").length+", selection="+Css.query(ta,a.node.id,".ui-code-peer-selection").length+", marks="+haxe.Json.stringify(a.documentState(fa).peers.get()));
			Snapshot.capture('jam-${dark ? "dark" : "light"}',ta,a.node,1100,760);
			var before=b.buffer(fb).get(); eb.editing.composing.set("文"); settle();
			ea.applyEdits([{from:0,to:0,text:"remote "}]);
			for (_ in 0...8) { settle(); Sys.sleep(.01); }
			check(b.buffer(fb).get()==before,"Remote update disturbed an active IME composition");
			eb.editing.composing.set(""); until(() -> b.buffer(fb).get()==a.buffer(fa).get(),"Deferred update did not arrive after composition");
			jb.pause(true); until(() -> jb.status.get()=="paused","Pause did not disconnect");
			eb.applyEdits([{from:0,to:0,text:"offline "}]);
			jb.pause(false); until(() -> jb.status.get()=="connected" && b.buffer(fb).get()==a.buffer(fa).get(),"Offline edits did not reconcile");
			var state=a.documentState(fa); a.openFile(root+"/host/other.txt"); settle();
			check(!state.mounted,"Inactive shared document retained its editor");
			eb.applyEdits([{from:0,to:0,text:"hidden "}]); until(() -> b.buffer(fb).get()==a.buffer(fa).get(),"Inactive document stopped synchronizing");
			a.openFile(fa); settle(); check(a.editorFor(fa).value.get()==b.buffer(fb).get(),"Reopened editor lost the shared document");
			until(() -> ja.recoveryStatus.get()=="saved locally" && jb.recoveryStatus.get()=="saved locally","Edits were not checkpointed");
			var finalText=a.buffer(fa).get(), firstInvite=ja.invite.get();
			a.runCommand("jam.leave");
			until(() -> jb.failure.get()!="","Host closure was not reported to the guest");
			b.runCommand("jam.leave"); settle();
			check(ja.closed && jb.closed && ja.document==-1 && jb.transport==-1,"Leaving retained native handles");
			check(state.onUndo==null && state.onTransaction==null && state.peers.get().length==0,"Leaving retained document callbacks or peer decorations");
			check(Css.query(ta,a.node.id,".ui-code-peer-caret").length==0 && a.jamPoll==null && b.jamPoll==null,"Leaving retained views or polling");
			check(sys.io.File.getContent(fa)==source && sys.io.File.getContent(fb)==source,"Jam wrote files without Save");
			// Recovery replaces only a clean buffer and never needs an active old presentation.
			a.runCommand("jam.resume"); settle(); check(a.prompt.get()==null,"Recovery offered to replace unsaved editor changes");
			a.documentState(fa).value.set(source); b.documentState(fb).value.set(source); a.saveAll(); b.saveAll(); settle();
			a.editorFor(fa).select(source.length,source.length);
			a.runCommand("jam.resume"); settle(); check(a.prompt.get()!=null && a.prompt.get().action=="Resume Jam","Resume command did not request explicit consent");
			a.prompt.get().accept(""); a.prompt.set(null);
			until(() -> a.jam.get().status.get()=="connected","Host did not resume");
			check(a.buffer(fa).get()==finalText && a.jam.get().invite.get()!=firstInvite,"Resume reseeded text or reused an invitation");
			b.runCommand("jam.rejoin"); settle(); check(b.prompt.get()!=null,"Rejoin did not request an invitation");
			b.prompt.get().accept(a.jam.get().invite.get()); b.prompt.set(null);
			until(() -> b.jam.get().status.get()=="connected" && a.jam.get().people.get().length==2,"Guest did not restore and rejoin");
			check(b.buffer(fb).get()==finalText,"Restored peers diverged");
			a.jam.get().checkpoint(); until(() -> a.jam.get().recoveryStatus.get()=="saved locally","Explicit checkpoint failed");
			a.runCommand("jam.leave"); b.runCommand("jam.leave"); settle();
			check(sys.io.File.getContent(fa)==source && sys.io.File.getContent(fb)==source,"Jam wrote files without Save");
		} catch (error:Dynamic) { sa(); sb(); ta.dispose(); tb.dispose(); ca.stop(); cb.stop(); throw error; }
		sa(); sb(); ta.dispose(); tb.dispose(); ca.stop(); cb.stop();
	}
}
