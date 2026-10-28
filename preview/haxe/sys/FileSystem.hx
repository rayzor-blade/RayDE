package sys;

import rayde.preview.Files;
class FileSystem {
    static function entry(path:String):Dynamic return Files.call("fs.stat",{path:Files.absolute(path)}).entry;
    public static function exists(path:String):Bool return entry(path)!=null;
    public static function isDirectory(path:String):Bool {var e=entry(path);return e!=null&&e.kind=="dir";}
    public static function readDirectory(path:String):Array<String> return [for(e in (Files.call("fs.list",{path:Files.absolute(path)}).entries:Array<Dynamic>))e.name];
    public static function fullPath(path:String):String return Files.absolute(path);
    public static function absolutePath(path:String):String return Files.absolute(path);
    public static function createDirectory(path:String):Void Files.call("fs.mkdir",{path:Files.absolute(path)});
    public static function deleteFile(path:String):Void Files.call("fs.remove",{path:Files.absolute(path)});
    public static function deleteDirectory(path:String):Void Files.call("fs.remove",{path:Files.absolute(path)});
    public static function rename(from:String,to:String):Void Files.call("fs.rename",{from:Files.absolute(from),to:Files.absolute(to)});
    public static function stat(path:String):FileStat {
        var e=entry(path);if(e==null)throw "No such file: "+path;
        var date=Date.fromTime(e.mtime);
        return {gid:0,uid:0,atime:date,mtime:date,ctime:date,size:e.size,dev:0,ino:0,nlink:1,rdev:0,mode:e.kind=="dir"?0x41ed:0x81a4};
    }
}
