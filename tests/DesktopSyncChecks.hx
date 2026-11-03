import ashui.components.code.CodeEditorState;
import rayde.sync.DesktopChannel;
import rayde.workspace.session.EditorDocuments;

/** Driven by the real gateway/browser-client check in web/cloud/test/desktop-bindings.mjs. */
class DesktopSyncChecks {
	static function check(value:Bool,message:String):Void if(!value)throw message;
	static function main():Void {
		var args=Sys.args(),root=args[0],client=DesktopChannel.connect(root,args[1],"alice"),state=new CodeEditorState();
		var file=root+"/a.txt",saved=false,disk=sys.io.File.getContent(file);state.value.set(disk);
		var docs=new EditorDocuments(client,(_,_) -> {},message -> {throw message;},_ -> {caret:0,anchor:0},_ -> false);
		function until(done:Void->Bool):Void {
			var end=haxe.Timer.stamp()+20;
			while(!done()){client.drain();docs.frame();if(haxe.Timer.stamp()>end)throw "Desktop document did not settle";Sys.sleep(.001);}
		}
		docs.attach(file,state,state.value.get());until(() -> !docs.readOnly(file));
		check(docs.owns(file),"published text must use the shared editor bridge");
		hl.Gc.major();
		Sys.println("DESKTOP_READY");Sys.stdin().readLine();
		docs.refresh(file);until(() -> state.value.get()=="browser base 🦀");
		check(sys.io.File.getContent(file)==disk,"cloud changes must remain unsaved in the desktop tree");
		state.value.set("native "+state.value.get());docs.acceptBuffer(file);
		docs.save(file,(error,text,_) -> {check(error==null,error);check(text=="native browser base 🦀","Save must return its accepted cloud version");saved=true;});
		until(() -> saved);check(sys.io.File.getContent(file)==state.value.get(),"Save must write the accepted graph to the desktop file");
		Sys.println("DESKTOP_SAVED");Sys.stdin().readLine();
		state.onUndo(false);until(() -> !docs.readOnly(file));check(state.value.get()=="browser base 🦀","author undo must retain the browser edit");
		docs.save(file,(error,text,_) -> {check(error==null,error);saved=false;});until(() -> !saved);
		docs.close();client.close();Sys.println("DESKTOP_DONE");
	}
}
