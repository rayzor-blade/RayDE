package rayde.workspace;

import haxe.io.Bytes;

/** RayDE's file calls, named as `sys.FileSystem` and `sys.io.File` name them, answered by the current `Workspace`. */
class Fs {
	/** Replaced at startup by a program that runs somewhere other than the machine its files are on. */
	public static var current:Workspace = new LocalWorkspace();

	public static inline function exists(path:String):Bool return current.exists(path);
	public static inline function isDirectory(path:String):Bool return current.isDirectory(path);
	public static inline function readDirectory(path:String):Array<String> return current.readDirectory(path);
	public static inline function stat(path:String):sys.FileStat return current.stat(path);
	public static inline function fullPath(path:String):String return current.fullPath(path);
	public static inline function absolutePath(path:String):String return current.absolutePath(path);
	public static inline function getContent(path:String):String return current.getContent(path);
	public static inline function getBytes(path:String):Bytes return current.getBytes(path);
	public static inline function readFrom(path:String, offset:Int):Bytes return current.readFrom(path, offset);
	public static inline function saveContent(path:String, content:String):Void current.saveContent(path, content);
	public static inline function saveBytes(path:String, bytes:Bytes):Void current.saveBytes(path, bytes);
	public static inline function createDirectory(path:String):Void current.createDirectory(path);
	public static inline function deleteFile(path:String):Void current.deleteFile(path);
	public static inline function deleteDirectory(path:String):Void current.deleteDirectory(path);
	public static inline function rename(path:String, to:String):Void current.rename(path, to);
	public static inline function copy(source:String, destination:String):Void current.copy(source, destination);
}
