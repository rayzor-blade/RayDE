import ashui.core.render.Offscreen;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.workspace.Fs;
import rayde.workspace.PageHost;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.Channel;
@:access(rayde.ui.Workbench)
@:access(rayde.workspace.PageHost)
class TerminalWorkbenchChecks {
 static function main() {
  var previous=Fs.current,previousSession=PageHost.session,home=Sys.getEnv("HOME"),extensions=Sys.getEnv("RAYDE_EXTENSIONS");
  var memory=new rayde.workspace.MemoryWorkspace();Fs.current=memory;
  for(path in ["/work/src","/work/extensions","/home/check"])memory.createDirectory(path);
  Sys.putEnv("HOME","/home/check");Sys.putEnv("RAYDE_EXTENSIONS","/work/extensions");
  memory.saveContent("/work/build.hxml","-cp src\n-main Main\n--interp\n");memory.saveContent("/work/src/Main.hx","class Main {static function main(){}}");
  var wire=new ProbeChannel(), client=SessionClient.over(wire);PageHost.session=client;
  ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),Dark);rayde.ui.Style.use();
  var tree=new LayoutTree(),compiler=new rayde.lang.CompilerServer(),stop:Void->Void=null;
  var bench=Owner.root(tree,c->{stop=c;return new rayde.ui.Workbench({display:rayde.lang.Display.ofHxml(compiler,"/work/build.hxml"),name:"Terminal probe"});});
  function frame(){client.drain();Offscreen.advance(.025);Css.update();tree.flush();tree.computeLayout(bench.node,1100,760);}
  for(_ in 0...10)frame();
  bench.toggleTerminal();
  for(_ in 0...20){frame();Sys.sleep(.005);}
  if(!bench.panelsPart.panelOpen()||bench.terminalPart.terminalCount()!=1||wire.opens!=1)throw "Terminal did not open asynchronously";
  function label():String {
   var ids=Css.query(tree,bench.node.id,"#rayde-terminal-shell");
   if(ids.length!=1)throw "Missing terminal shell identity";
   return ashui.ui.Text.at(ids[0]).text();
  }
  if(label()!="sh")throw "Default terminal did not identify its shell";
  var first=bench.terminalPart.terminalIds()[0];
  bench.terminalPart.newTerminal({name:"bash",program:"/bin/bash"});
  for(_ in 0...12){frame();Sys.sleep(.005);}
  if(label()!="bash")throw "New terminal retained the preceding shell label";
  bench.terminalPart.selectTerminal(first);for(_ in 0...8)frame();
  if(label()!="sh")throw "Selecting a terminal did not update its shell label";
  var labelId=Css.query(tree,bench.node.id,"#rayde-terminal-shell")[0],box=tree.getScrolledBounds(new ashui.layout.Node(labelId));
  if(box.width<=0||box.height<=0||box.x+box.width>1100)throw "Terminal shell label is clipped";
  ashui.core.render.Snapshot.capture("terminal-shell-toolbar",tree,bench.node,1100,760);
  var ids=Css.query(tree,bench.node.id,"#rayde-terminal");
  if(ids.length!=1)throw "Terminal view was lost when switching shells";
  stop();tree.dispose();client.close();compiler.stop();Fs.current=previous;PageHost.session=previousSession;Sys.putEnv("HOME",home);Sys.putEnv("RAYDE_EXTENSIONS",extensions);
  Sys.println("Terminal workbench: nonblocking opening, active/default shell identity and shell switching passed");
 }
}
private class ProbeChannel implements Channel {
 var incoming=new sys.thread.Deque<String>();public var opens=0;
 public function new(){}
 public function sendText(text:String){var r:Dynamic=haxe.Json.parse(text);var v:Dynamic={id:r.id,ok:true};switch(r.op:String){case 'hello':v.root='/work';v.name='work';v.terminal=true;v.exec=true;v.terminalProfiles=[{name:'sh',program:'/bin/sh'}];case 'term.open':opens++;return;default:}incoming.add(haxe.Json.stringify(v));}
 public function receive(seconds:Float):Null<String>{var v=incoming.pop(true);if(v=='closed')throw 'closed';return v;}
 public function close()incoming.add('closed');
}
