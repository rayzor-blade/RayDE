package rayde.workspace;

import haxe.io.Bytes;
import sys.FileSystem;
import sys.io.File;

/** The machine's own filesystem. */
class LocalWorkspace implements Workspace {
	public function new() {}

	public function exists(path:String):Bool return FileSystem.exists(path);
	public function isDirectory(path:String):Bool return FileSystem.isDirectory(path);
	public function readDirectory(path:String):Array<String> return FileSystem.readDirectory(path);
	public function stat(path:String):sys.FileStat return FileSystem.stat(path);
	public function fullPath(path:String):String return FileSystem.fullPath(path);
	public function absolutePath(path:String):String return FileSystem.absolutePath(path);
	public function getContent(path:String):String return File.getContent(path);
	public function getBytes(path:String):Bytes return File.getBytes(path);
	public function readFrom(path:String, offset:Int):Bytes {
		var input = File.read(path, true);
		try {
			input.seek(offset, SeekBegin);
			var bytes = input.readAll();
			input.close();
			return bytes;
		} catch (e:Dynamic) {
			input.close();
			throw e;
		}
	}
	public function saveContent(path:String, content:String):Void File.saveContent(path, content);
	public function saveBytes(path:String, bytes:Bytes):Void File.saveBytes(path, bytes);
	public function createDirectory(path:String):Void FileSystem.createDirectory(path);
	public function deleteFile(path:String):Void FileSystem.deleteFile(path);
	public function deleteDirectory(path:String):Void FileSystem.deleteDirectory(path);
	public function rename(path:String, to:String):Void FileSystem.rename(path, to);
	public function copy(source:String, destination:String):Void File.copy(source, destination);
}
