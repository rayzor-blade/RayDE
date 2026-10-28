package sys.io;

import haxe.io.Bytes;
import rayde.preview.Files;

typedef FileHandle = hl.Abstract<"hl_fdesc">;

class File {
    public static function getContent(path:String):String return getBytes(path).toString();
    public static function getBytes(path:String):Bytes return Files.bytes(path);
    public static function saveContent(path:String,content:String):Void saveBytes(path,Bytes.ofString(content));
    public static function saveBytes(path:String,bytes:Bytes):Void Files.save(path,bytes);
    public static function read(path:String,binary=true):FileInput return new MemoryInput(getBytes(path));
    public static function write(path:String,binary=true):FileOutput return new MemoryOutput(path,0);
    public static function append(path:String,binary=true):FileOutput return new MemoryOutput(path,2);
    public static function update(path:String,binary=true):FileOutput return new MemoryOutput(path,1);
    public static function copy(source:String,destination:String):Void saveBytes(destination,getBytes(source));
}

private class MemoryInput extends FileInput {
    final bytes:haxe.io.BytesInput;
    final size:Int;
    public function new(data:Bytes){super(null);bytes=new haxe.io.BytesInput(data);size=data.length;}
    override public function readByte():Int return bytes.readByte();
    override public function readBytes(data:Bytes,pos:Int,len:Int):Int return bytes.readBytes(data,pos,len);
    override public function close():Void {}
    override public function seek(offset:Int,position:FileSeek):Void bytes.position=switch position{case SeekBegin:offset;case SeekCur:bytes.position+offset;case SeekEnd:size+offset;};
    override public function tell():Int return bytes.position;
    override public function eof():Bool return bytes.position>=size;
}

private class MemoryOutput extends FileOutput {
    final path:String;
    var data:Bytes;
    var position:Int;
    var closed=false;
    public function new(path:String,mode:Int){super(null);this.path=path;data=mode!=0&&sys.FileSystem.exists(path)?File.getBytes(path):Bytes.alloc(0);position=mode==2?data.length:0;}
    override public function writeByte(value:Int):Void {var bytes=Bytes.alloc(1);bytes.set(0,value);writeBytes(bytes,0,1);}
    override public function writeBytes(bytes:Bytes,pos:Int,len:Int):Int {
        if(closed)throw "The preview file is closed.";
        if(pos<0||len<0||pos+len>bytes.length)throw haxe.io.Error.OutsideBounds;
        if(position+len>8*1024*1024)throw "The preview file is too large.";
        if(position+len>data.length){var next=Bytes.alloc(position+len);next.blit(0,data,0,data.length);data=next;}
        data.blit(position,bytes,pos,len);position+=len;return len;
    }
    override public function flush():Void {if(!closed)Files.save(path,data);}
    override public function close():Void {flush();closed=true;}
    override public function tell():Int return position;
    override public function seek(offset:Int,origin:FileSeek):Void {
        var next=switch origin{case SeekBegin:offset;case SeekCur:position+offset;case SeekEnd:data.length+offset;};
        if(next<0||next>8*1024*1024)throw haxe.io.Error.OutsideBounds;position=next;
    }
}
