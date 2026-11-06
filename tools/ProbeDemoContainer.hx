import haxe.crypto.Sha256;
import rayde.workspace.session.SessionClient;
import rayde.workspace.session.SessionLauncher;

/** Acceptance probe for a running private demo image; the credential stays in a file. */
class ProbeDemoContainer {
    static function check(value:Bool, message:String):Void if (!value) throw message;
    static function terminal(client:SessionClient):Void {
        var mutex=new sys.thread.Mutex(), ready=false, failure:Null<String>=null;
        var rows=new Map<Int,String>();
        var remove=client.subscribePrograms(event -> {
            mutex.acquire();
            if(event.ev=="term.ready")ready=true;
            if(event.ev=="term.failed")failure=event.message;
            if(event.ev=="term.update")for(row in (event.rows:Array<Dynamic>))rows.set(row.row,row.text);
            mutex.release();
            if(event.ev=="term.update")client.notify("term.ack",{tid:event.tid});
        });
        var opened=client.request("term.open",{key:"image-proof",cols:100,rows:12});
        var deadline=haxe.Timer.stamp()+15;
        while(true) {
            mutex.acquire();var done=ready, error=failure;mutex.release();
            if(error!=null)throw error;
            if(done)break;
            check(haxe.Timer.stamp()<deadline,"The image terminal did not become ready");Sys.sleep(.01);
        }
        client.request("term.write",{tid:opened.tid,data:"printf '__RAYDE_%s__\\n' PTY_OK\r"});
        deadline=haxe.Timer.stamp()+15;
        while(true) {
            mutex.acquire();var screen=[for(row in rows)row].join("\n");mutex.release();
            if(screen.indexOf("__RAYDE_PTY_OK__")>=0)break;
            check(haxe.Timer.stamp()<deadline,"The image terminal did not execute input");Sys.sleep(.01);
        }
        client.request("term.close",{tid:opened.tid});remove();
    }
    static function main():Void {
        var args=Sys.args();
        check(args.length==4,"Use ProbeDemoContainer HOST:PORT TOKEN_FILE ACTION MARKER");
        var address=args[0].split(":"),token=StringTools.trim(sys.io.File.getContent(args[1]));
        var client=SessionClient.connect(address[0],Std.parseInt(address[1]),token);
        try {
            check(client.exec && client.terminal && client.syntax && client.appPreviews,"Demo capabilities are incomplete");
            check(client.extensionHost!=null && client.extensionsRoot!=null,"Built-in extension installation is missing");
            var file="visitor-image-proof.txt";
            switch(args[2]) {
                case "absent":check(client.request("fs.stat",{path:file}).entry==null,"Another visitor's file entered this image");
                case "write":client.request("fs.write",{path:file,data:args[3]});
                case "read":check(client.request("fs.read",{path:file}).data==args[3],"Visitor content did not survive reconnect");
                case "services":
                    var process=new SessionLauncher(client).startAsync("/bin/sh",["-c","test -z \"$RAYDE_DEMO_TOKEN$RAYDE_DEMO_ID$RUNNER_SECRET$GITHUB_CLIENT_SECRET\" && printf image-environment-clean"]).await();
                    var output=process.stdout.readAll().toString(),code=process.exitCode();process.close();
                    check(code==0 && output=="image-environment-clean","A child process inherited a control credential");
                    for(sample in [
                        {file:"example.js",source:"const answer = \"ready\";"},
                        {file:"example.rs",source:"fn main() { let answer = \"ready\"; }"},
                        {file:"example.toml",source:'name = "ready"'}
                    ]) {
                        var highlighted=client.request("syntax.highlight",{key:"image-proof",file:sample.file,source:sample.source});
                        var styled=false;
                        for(line in (highlighted.tokens:Array<Array<Dynamic>>))for(token in line)if(token.kind=="string")styled=true;
                        check(styled,"Syntax highlighting is missing for "+sample.file);
                    }
                    terminal(client);
                case _:throw "Unknown image probe action";
            }
            var identity=client.request("hello",{token:token}).cacheIdentity;
            Sys.println(haxe.Json.stringify({action:args[2],passed:true,namespace:Sha256.encode(haxe.Json.stringify(identity))}));
            client.close();
        } catch(error:Dynamic){client.close();throw error;}
    }
}
