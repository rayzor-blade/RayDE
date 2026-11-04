import haxe.crypto.Base64;
import haxe.io.Bytes;
import rayde.term.RemoteTerminal;
import rayde.ui.TerminalView;
import rayde.workspace.session.Channel;
import rayde.workspace.session.SessionClient;

class RemoteTerminalChecks {
    static function check(value:Bool,message:String):Void if (!value) throw message;
    static function until(done:Void->Bool):Void {var end=haxe.Timer.stamp()+5;while(!done()&&haxe.Timer.stamp()<end) Sys.sleep(.005);check(done(),"Terminal did not settle");}
    static function main():Void {
        var wire=new TerminalChannel(),client=SessionClient.over(wire);
        check(client.terminal&&client.terminalProfiles[0].program=="/remote/shell","Host terminal capability/profiles missing");
        var early=new RemoteTerminal(client,80,20,"");until(()->wire.count("term.open")==1);
        var first=wire.last("term.open");check(early.starting()&&early.write("early"),"Pending terminal rejected bounded input");early.close();wire.reply({id:first.id,ok:true,tid:1});until(()->wire.count("term.close")==1);
        check(early.handle==1&&early.exitCode()==-3,"A late open revived the closed terminal");
        var terminal=new RemoteTerminal(client,80,20,"");until(()->wire.count("term.open")==2);var open=wire.last("term.open");
        wire.reply({id:open.id,ok:true,tid:2});wire.reply({ev:"term.ready",tid:2,key:open.key});
        until(()->terminal.revision()>1);check(terminal.starting(),"Readiness hid loading before the first screen arrived");
        var info=Bytes.alloc(16);info.setUInt16(0,2);info.setUInt16(2,6);info.set(8,5);
        var text="A🙂éZ",utf8=Bytes.ofString(text),runs=Bytes.alloc(19+utf8.length);runs.setInt32(0,15+utf8.length);runs.setUInt16(6,5);runs.set(8,1);runs.setInt32(9,0x01000001);runs.setUInt16(17,utf8.length);runs.blit(19,utf8,0,utf8.length);
        var columns=Bytes.alloc(14);var offsets=[0,1,1,3,5,6,7];for(i in 0...offsets.length)columns.setUInt16(i*2,offsets[i]);
        var update={ev:"term.update",tid:2,key:open.key,info:Base64.encode(info),exit:-1,rows:[{row:0,runs:Base64.encode(runs),text:text+" ",columns:Base64.encode(columns)}]};wire.reply(update);
        until(()->terminal.screen().rows==2);check(!terminal.starting()&&terminal.screen().bracketedPaste,"Remote screen flags missing");
        check(terminal.text(0,1,0,3)=="🙂"&&terminal.text(0,3,0,4)=="é","Selection split a wide or combining character");
        check(terminal.dirtyRows().indexOf(0)>=0,"Changed row missing");check(terminal.row(0)[0].fg==0x01000001,"ANSI run lost its color");check(terminal.dirtyRows().length==0,"Consumed row remained dirty");
        until(()->wire.count("term.resize")>=1);var before=wire.count("term.resize");terminal.resize(90,25);terminal.resize(90,25);until(()->wire.count("term.resize")==before+1);
        terminal.setVisible(false);terminal.setVisible(false);until(()->wire.last("term.visible").visible==false);
        #if rayde_page
        ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),Dark);rayde.ui.Style.use();
        var tree=new ashui.layout.LayoutTree(),dispose:Void->Void=null;terminal.invalidate();
        var root=ashui.reactive.Owner.root(tree,cleanup->{dispose=cleanup;return <div width={820} height={220} class="flex flex-col"><terminal-view terminal={terminal} shown={() -> true} class="flex-1 min-h-0"/></div>;});
        function frame():Void {ashui.core.render.Offscreen.advance(.02);ashui.css.Css.setViewport(820,220);ashui.css.Css.update();tree.flush();tree.computeLayout(root.node,820,220);}
        for(_ in 0...20){frame();Sys.sleep(.005);}var requested=wire.count("term.resize");
        for(_ in 0...20)frame();check(wire.count("term.resize")==requested,"A pending resize kept rebuilding its view");
        update.exit=127;wire.reply(update);until(()->terminal.exitCode()==127);for(_ in 0...4)frame();
        check(ashui.css.Css.query(tree,root.node.id,"#rayde-terminal-exit").length==1&&ashui.css.Css.query(tree,root.node.id,"#rayde-terminal-failure").length==0,"A program exit was mistaken for a terminal service failure");
        dispose();tree.dispose();
        #end
        wire.reply({ev:"term.failed",tid:2,key:open.key,message:"PTY failed"});until(()->terminal.failedToStart());check(!terminal.write("late"),"Failed terminal accepted input");
        until(()->wire.count("term.close")==2);wire.reply(update);Sys.sleep(.02);check(terminal.failedToStart(),"A late update revived a failed terminal");terminal.close();client.close();
        #if rayde_page
        Sys.putEnv("ASHUI_SNAPSHOT_DIR","bin/cloud-terminal-shots");
        failureView(true);failureView(false);
        #end
        Sys.println("Remote terminal: host metadata, late-open cancellation, Unicode copy, ANSI, dirty rows, resize coalescing, delayed-screen layout and failure cleanup passed");
    }

    #if rayde_page
    static function failureView(dark:Bool):Void {
        ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),dark?Dark:Light);
        var wire=new TerminalChannel(),client=SessionClient.over(wire),terminal=new RemoteTerminal(client,80,20,"");
        until(()->wire.count("term.open")==1);var open=wire.last("term.open"),retried=0;
        var tree=new ashui.layout.LayoutTree(),dispose:Void->Void=null;
        var root=ashui.reactive.Owner.root(tree,cleanup->{dispose=cleanup;return <div id="rayde" width={440} height={220} class="flex flex-col bg-background text-text-primary"><terminal-view terminal={terminal} shown={() -> true} onRestart={() -> retried++}/></div>;});
        function frame():Void {ashui.core.render.Offscreen.advance(.02);ashui.css.Css.setViewport(440,220);ashui.css.Css.update();tree.flush();tree.computeLayout(root.node,440,220);}
        function has(selector:String):Bool return ashui.css.Css.query(tree,root.node.id,selector).length==1;
        for(_ in 0...12)frame();check(has("#rayde-terminal-starting"),"Delayed startup left the panel blank");
        ashui.core.render.Snapshot.capture("terminal-starting-"+(dark?"dark":"light"),tree,root.node,440,220);
        var message="The workspace did not answer the terminal startup request. Reconnect and retry the terminal.";
        wire.reply({id:open.id,ok:false,code:"timeout",message:message});until(()->terminal.failedToStart());
        for(_ in 0...12)frame();
        check(has("#rayde-terminal-failure")&&has("#rayde-terminal-retry")&&!has("#rayde-terminal-starting")&&!has("#rayde-terminal-exit"),"Startup failure was reduced to an exit code or retained loading");
        var text=ashui.css.Css.query(tree,root.node.id,"#rayde-terminal-failure text");
        check(Lambda.exists(text,id->ashui.ui.Text.at(id)!=null&&ashui.ui.Text.at(id).text()==message),"Terminal lost the underlying failure reason");
        var id=ashui.css.Css.query(tree,root.node.id,"#rayde-terminal-retry")[0],b=tree.getScrolledBounds(new ashui.layout.Node(id));
        check(b.width>0&&b.height>0&&b.x+b.width<=440,"Retry action did not fit the terminal panel");
        ashui.input.Pointer.move(tree,b.x+b.width/2,b.y+b.height/2);ashui.input.Pointer.press(tree);ashui.input.Pointer.release(tree);frame();
        check(retried==1,"Terminal retry action did not fire");
        for(_ in 0...200)frame();check(has("#rayde-terminal-failure"),"The failure disappeared before it could be read");
        ashui.core.render.Snapshot.capture("terminal-startup-failure-"+(dark?"dark":"light"),tree,root.node,440,220);
        dispose();tree.dispose();terminal.close();client.close();
    }
    #end
}

private class TerminalChannel implements Channel {
    final input=new sys.thread.Deque<String>();final mutex=new sys.thread.Mutex();final requests:Array<Dynamic>=[];
    public function new(){}
    public function reply(value:Dynamic):Void input.add(haxe.Json.stringify(value));
    public function count(op:String):Int {mutex.acquire();var n=[for(r in requests)if(r.op==op)r].length;mutex.release();return n;}
    public function last(op:String):Dynamic {mutex.acquire();var value:Dynamic=null;for(r in requests)if(r.op==op)value=r;mutex.release();return value;}
    public function sendText(text:String):Void {
        var request:Dynamic=haxe.Json.parse(text);mutex.acquire();requests.push(request);mutex.release();
        if(request.op=="hello")reply({id:request.id,ok:true,root:"/work",name:"work",terminal:true,terminalProfiles:[{name:"remote",program:"/remote/shell"}]});
        else if(request.op!="term.open"&&request.id!=null)reply({id:request.id,ok:true});
    }
    public function receive(seconds:Float):Null<String>{var text=input.pop(true);if(text=="closed")throw "closed";return text;}
    public function close():Void input.add("closed");
}
