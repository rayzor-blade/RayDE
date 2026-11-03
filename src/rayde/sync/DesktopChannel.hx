package rayde.sync;

import rayde.workspace.session.Channel;
import rayde.workspace.session.SessionClient;

/** Cloud editor I/O runs on native workers; the existing session receiver completes futures. */
class DesktopChannel implements Channel {
	final handle:Int;
	var closed=false;
	function new(config:Dynamic){
		var bytes=haxe.io.Bytes.ofString(haxe.Json.stringify(config));handle=open(bytes.getData(),bytes.length);
		if(handle<0)throw "Could not start desktop document sync.";
	}
	public static function connect(root:String,gateway:String,account:String):SessionClient
		return SessionClient.over(new DesktopChannel({root:root,gateway:gateway,account:account}));
	public function sendText(text:String):Void {
		if(closed)throw "Desktop document sync is closed.";
		var bytes=haxe.io.Bytes.ofString(text);
		if(!send(handle,bytes.getData(),bytes.length))throw "The desktop document sync queue is unavailable.";
	}
	public function receive(seconds:Float):Null<String>{
		if(closed)throw "Desktop document sync is closed.";
		var bytes=read(handle,seconds);if(bytes==null)return null;
		var length=bytes.getI32(0),text=bytes.sub(4,length).toBytes(length).toString();
		if(text=='{"ev":"session.disconnected"}')throw "Desktop document sync disconnected.";
		return text;
	}
	public function close():Void {if(closed)return;closed=true;release(handle);}
	@:hlNative("rayscript","sync_editor_open") static function open(bytes:hl.Bytes,length:Int):Int return -1;
	@:hlNative("rayscript","sync_editor_send") static function send(handle:Int,bytes:hl.Bytes,length:Int):Bool return false;
	@:hlNative("rayscript","sync_editor_receive") static function read(handle:Int,seconds:Float):hl.Bytes return null;
	@:hlNative("rayscript","sync_editor_close") static function release(handle:Int):Void {}
}
