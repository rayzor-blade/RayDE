import rayde.run.AppPreviewCompiler;
import rayde.run.BuildProgress;
import rayde.run.RunConfigurations;
import rayde.workspace.PageHost;
import rayde.workspace.session.SessionClient;

/** Operator preparation uses the same planner, compiler supervision and cache as Preview App. */
class PrepareDemoPreview {
    static function copy(source:String, destination:String):Void {
        sys.FileSystem.createDirectory(destination);
        for (name in sys.FileSystem.readDirectory(source)) {
            var from=source+"/"+name,to=destination+"/"+name;
            if(sys.FileSystem.isDirectory(from))copy(from,to);
            else if(!StringTools.endsWith(name,".hl"))sys.io.File.copy(from,to);
        }
    }
    static function main():Void {
        var args=Sys.args();
        if(args.length!=3 && !(args.length==4 && args[3]=="--framed"))throw "Use PrepareDemoPreview HOST:PORT TOKEN_FILE OUTPUT_DIRECTORY [--framed]";
        var address=args[0].split(":"),token=StringTools.trim(sys.io.File.getContent(args[1]));
        var client=args.length==4 ? SessionClient.connectFramed(address[0],Std.parseInt(address[1]),token) : SessionClient.connect(address[0],Std.parseInt(address[1]),token);
        var progress=new BuildProgress();
        try {
            PageHost.install(client,null,false);
            var manifest=client.root+"/build.hxml",inputs=rayde.lang.Hxml.read(manifest);
            var configuration=RunConfigurations.load(client.root,"hl",true);
            var build={client:client,compiler:"haxe",args:inputs,cwd:client.root,progress:progress,force:false,family:"haxe",manifest:manifest};
            var result=AppPreviewCompiler.build(build,()->false);
            Sys.println(result.output);
            client.request("preview.close",{preview:result.artifact.preview});
            client.request("preview.discard",{path:result.artifact.path});
            progress=new BuildProgress();build.progress=progress;result=AppPreviewCompiler.build(build,()->false);
            if(result.output.indexOf("Reusing unchanged preview bundle.")<0)throw "The prepared demo did not reuse its WASM cache.";
            if(args[2]!="-") {
                copy(client.root+"/"+result.artifact.path,args[2]);
                sys.io.File.saveContent(args[2]+"/configuration.json",haxe.Json.stringify(configuration));
            }
            Sys.println(result.output);
            client.request("preview.close",{preview:result.artifact.preview});
            client.request("preview.discard",{path:result.artifact.path});
            client.close();
        } catch(error:Dynamic){Sys.stderr().writeString(progress.snapshot().output);client.close();throw error;}
    }
}
