package rayde.workspace;

import haxe.io.Bytes;

/**
 * Where RayDE's files live. On a desktop it is the local filesystem; in a page it is a session (docs/session.md).
 * The calls are synchronous, as `sys.FileSystem`'s are: a provider that has to ask a remote session suspends the caller until it answers.
 */
interface Workspace {
	function exists(path:String):Bool;
	function isDirectory(path:String):Bool;
	function readDirectory(path:String):Array<String>;
	function stat(path:String):sys.FileStat;
	function fullPath(path:String):String;
	function absolutePath(path:String):String;
	function getContent(path:String):String;
	function getBytes(path:String):Bytes;
	/** What the file holds from byte `offset` on: a log read as it grows. */
	function readFrom(path:String, offset:Int):Bytes;
	function saveContent(path:String, content:String):Void;
	function saveBytes(path:String, bytes:Bytes):Void;
	function createDirectory(path:String):Void;
	function deleteFile(path:String):Void;
	function deleteDirectory(path:String):Void;
	/** The destination's directory must exist, as `sys.FileSystem.rename` needs. */
	function rename(path:String, to:String):Void;
	function copy(source:String, destination:String):Void;
}
