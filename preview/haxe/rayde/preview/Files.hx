package rayde.preview;

import haxe.io.Bytes;

/** Preview-only stdlib I/O crosses the editor's bounded workspace channel. */
class Files {
    static var handle=0;
    static var next=0;
    static var root:Null<String>;
    static final mutex=new sys.thread.Mutex();

    public static function call(op:String,params:Dynamic):Dynamic {
        mutex.acquire();
        try {
            if (handle==0) {
                var name=Bytes.ofString("rayde_preview_files");
                handle=open(name.getData(),name.length,65536);
                if(handle==0)throw "This app needs its editor preview filesystem.";
            }
            params.op=op;params.id=++next;
            var bytes=Bytes.ofString(haxe.Json.stringify(params)),frame=Bytes.alloc(bytes.length+4);
            frame.set(0,bytes.length>>>24);frame.set(1,bytes.length>>>16);frame.set(2,bytes.length>>>8);frame.set(3,bytes.length);frame.blit(4,bytes,0,bytes.length);
            var at=0;
            while(at<frame.length) {
                var count=Std.int(Math.min(16384,frame.length-at)),part=frame.sub(at,count),code=send(handle,part.getData(),0,count);
                if(code==1){Sys.sleep(.001);continue;}if(code!=0)throw "The preview filesystem disconnected.";at+=count;
            }
            var first=receive(),size=first.get(0)<<24|first.get(1)<<16|first.get(2)<<8|first.get(3);
            if(size<0||size>16*1024*1024)throw "The preview filesystem reply is too large.";
            var result=Bytes.alloc(size),used=first.length-4;
            result.blit(0,first,4,used);
            while(used<size){var part=receive();result.blit(used,part,0,part.length);used+=part.length;}
            var reply:Dynamic=haxe.Json.parse(result.toString());
            if(reply.ok!=true)throw reply.message==null?"The preview filesystem request failed.":reply.message;
            mutex.release();return reply;
        } catch(error:Dynamic){mutex.release();throw error;}
    }
    static function receive():Bytes {
        var raw:hl.Bytes=recv(handle).await();var size=raw.getI32(0);return raw.toBytes(4+size).sub(4,size);
    }
    public static function absolute(path:String):String {
        if(root==null)root=call("preview.fs.hello",{}).root;
        var base=StringTools.startsWith(path,"/")?path:root+"/"+path;
        return haxe.io.Path.normalize(base);
    }
    public static function bytes(path:String):Bytes return haxe.crypto.Base64.decode(call("fs.read",{path:absolute(path),encoding:"base64"}).data);
    public static function save(path:String,data:Bytes):Void call("fs.write",{path:absolute(path),data:haxe.crypto.Base64.encode(data),encoding:"base64"});
    @:hlNative("ash_channel","channel_open") static function open(name:hl.Bytes,length:Int,capacity:Int):Int return 0;
    @:hlNative("ash_channel","channel_send") static function send(handle:Int,data:hl.Bytes,pos:Int,len:Int):Int return 0;
    @:hlNative("ash_channel","channel_recv") static function recv(handle:Int):ash.Future<hl.Bytes> return null;
}
