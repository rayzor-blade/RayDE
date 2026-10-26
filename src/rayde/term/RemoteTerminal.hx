package rayde.term;

import haxe.crypto.Base64;
import haxe.io.Bytes;
import rayde.term.Terminal.Run;
import rayde.term.Terminal.Screen;
import rayde.workspace.PageHost;
import rayde.workspace.session.SessionClient;

/** A bounded local screen mirror. PTY operations use session futures; rendering never waits for RPC. */
class RemoteTerminal {
	static var next = 0;
	public final remote = true;
	public final program:String;
	public var handle(default,null) = -1;
	final client:SessionClient;
	final generation:Int;
	final key:String;
	final mutex = new sys.thread.Mutex();
	var unsubscribe:Void->Void;
	var closed = false;
	var state = 0;
	var code = -1;
	var version = 1;
	var failure:Null<String>;
	var visible = true;
	var wantedCols:Int;
	var wantedRows:Int;
	var pending = "";
	var grid:Screen = empty();
	var rows:Array<Array<Run>> = [];
	var copies:Array<{text:String,columns:Bytes}> = [];
	var dirty = new Map<Int,Bool>();

	static function empty():Screen return {rows:0,cols:0,cursorRow:0,cursorColumn:0,cursorShown:false,applicationCursor:false,bracketedPaste:false,alternate:false,mouseMode:0,mouseEncoding:0,scrollback:0};

	public static function open(cols:Int,rows:Int,?cwd:String,?program:String,?args:Array<String>,background=false):Null<RemoteTerminal> {
		var client = PageHost.session;
		if (client == null || !client.terminal || !client.isOnline()) return null;
		var directory = "";
		if (cwd != null && cwd != "") {
			if (!rayde.files.FileOps.inside(client.root,cwd)) return null;
			directory = cwd == client.root ? "" : rayde.files.FileOps.relative(client.root,cwd);
		}
		return new RemoteTerminal(client,cols,rows,directory,program,args);
	}

	public function new(client:SessionClient,cols:Int,rows:Int,cwd:String,?program:String,?args:Array<String>) {
		this.client = client;this.program = program == null || program == "" ? "shell" : program;
		generation = client.connectionEpoch();key = "terminal-" + next++;wantedCols = cols;wantedRows = rows;
		unsubscribe = client.subscribePrograms(receive);
		client.requestAsync("term.open",{key:key,cols:cols,rows:rows,cwd:cwd,program:program,args:args,sessionGeneration:generation},15).then(reply -> {
			mutex.acquire();handle = reply.tid;
			var stop = closed || state == -1 || generation != client.connectionEpoch(), text = pending;pending = "";
			if (!stop) {command("term.resize",{cols:wantedCols,rows:wantedRows});command("term.visible",{visible:visible});if (text != "") command("term.write",{data:text});}
			mutex.release();
			if (stop && generation == client.connectionEpoch()) try client.notify("term.close",{tid:reply.tid,sessionGeneration:generation}) catch (_:Dynamic) {}
			ashui.core.Work.notify();
		},fail);
	}

	function fail(error:Dynamic):Void {
        mutex.acquire();var changed = !closed && state != -1,id = handle;
        if (changed) {failure = Std.isOfType(error,rayde.workspace.session.SessionClient.SessionFailure) ? (cast error:rayde.workspace.session.SessionClient.SessionFailure).message : Std.string(error);state = -1;code = 127;pending = "";version++;}
        mutex.release();
        if (changed) {
            Sys.println("Terminal: " + failure);
            if (unsubscribe != null) unsubscribe();
            if (id >= 0 && generation == client.connectionEpoch()) try client.notify("term.close",{tid:id,sessionGeneration:generation}) catch (_:Dynamic) {}
            ashui.core.Work.notify();
        }
    }

	function receive(event:Dynamic):Void {
		if (event.ev == "session.disconnected") {fail("Session disconnected. Start a new terminal after reconnecting.");return;}
		if (event.key != key || generation != client.connectionEpoch()) return;
		if (event.ev == "term.failed") {fail(event.message);return;}
		var ack = false,error:Dynamic = null;
		mutex.acquire();
		if (closed || state == -1) {mutex.release();return;}
		try switch (event.ev:String) {
			case "term.ready": state = 1;version++;
			case "term.update":
				var b = Base64.decode(event.info),flags = b.get(8),height = b.getUInt16(0),width = b.getUInt16(2);
				if (height > 100 || width > 300) throw "Invalid terminal screen dimensions.";
				grid = {rows:height,cols:width,cursorRow:b.getUInt16(4),cursorColumn:b.getUInt16(6),cursorShown:flags&1!=0,applicationCursor:flags&2!=0,bracketedPaste:flags&4!=0,alternate:flags&8!=0,mouseMode:b.get(9),mouseEncoding:b.get(10),scrollback:b.getUInt16(12)};
				rows.resize(height);copies.resize(height);
				for (line in (event.rows:Array<Dynamic>)) {
					var index:Int = line.row;if (index < 0 || index >= height) throw "Invalid terminal row.";
					rows[index] = decodeRow(Base64.decode(line.runs));copies[index] = {text:line.text,columns:Base64.decode(line.columns)};dirty.set(index,true);
				}
				code = event.exit;state = 1;version++;ack = true;
			case _:
		} catch(problem:Dynamic) {error = problem;}
		mutex.release();
		if (error != null) fail(error);
		if (ack) try client.notify("term.ack",{tid:event.tid,sessionGeneration:generation}) catch(error:Dynamic) {fail(error);}
	}

	static function decodeRow(b:Bytes):Array<Run> {
		var length = b.getInt32(0),at = 4,out:Array<Run> = [];
		if (length != b.length-4) throw "Invalid terminal row data.";
		while (at < b.length) {
			var size = b.getUInt16(at+13);
			out.push({col:b.getUInt16(at),cells:b.getUInt16(at+2),attrs:b.get(at+4),fg:b.getInt32(at+5),bg:b.getInt32(at+9),text:b.getString(at+15,size)});at += 15+size;
		}
		return out;
	}

	/** The caller holds the mirror lock so startup, close and input preserve their order. */
	function command(op:String,params:Dynamic):Void {
		if (closed || handle < 0) return;
		params.tid = handle;params.sessionGeneration = generation;
		client.requestAsync(op,params,10).then(_ -> {},fail);
	}
	public function write(text:String):Bool {
		mutex.acquire();var ok = !closed && state >= 0 && text.length <= 65536;
		if (ok) {if (handle < 0) {ok = pending.length+text.length <= 65536;if (ok) pending += text;}else command("term.write",{data:text});}
		mutex.release();return ok;
	}
	public function setVisible(on:Bool):Void {mutex.acquire();if (visible != on) {visible = on;command("term.visible",{visible:on});}mutex.release();}
	public function resize(cols:Int,rows:Int):Void {
        cols = Std.int(Math.min(300,Math.max(2,cols)));rows = Std.int(Math.min(100,Math.max(1,rows)));
        mutex.acquire();if (cols != wantedCols || rows != wantedRows) {wantedCols = cols;wantedRows = rows;command("term.resize",{cols:cols,rows:rows});}mutex.release();
    }
	public function scrollback(lines:Int):Int {mutex.acquire();command("term.scroll",{lines:lines});var value = grid.scrollback;mutex.release();return value;}
	public function starting():Bool {mutex.acquire();var value = !closed && state == 0;mutex.release();return value;}
	public function failedToStart():Bool {mutex.acquire();var value = state == -1;mutex.release();return value;}
	public function failureReason():Null<String> {mutex.acquire();var value = failure;mutex.release();return value;}
	public function revision():Int {mutex.acquire();var value = version;mutex.release();return value;}
	public function exitCode():Int {mutex.acquire();var value = closed ? -3 : code;mutex.release();return value;}
	public function screen():Screen {mutex.acquire();var value = grid;mutex.release();return value;}
	public function row(index:Int):Array<Run> {mutex.acquire();var value = index >= 0 && index < rows.length && rows[index] != null ? rows[index] : [];dirty.remove(index);mutex.release();return value;}
	public function dirtyRows():Array<Int> {mutex.acquire();var value = [for (i in dirty.keys()) i];mutex.release();return value;}
	public function invalidate():Void {mutex.acquire();for (i in 0...rows.length) dirty.set(i,true);version++;mutex.release();}
	public function line(index:Int):String {mutex.acquire();var value = index >= 0 && index < copies.length && copies[index] != null ? StringTools.rtrim(copies[index].text) : "";mutex.release();return value;}
	public function text(r1:Int,c1:Int,r2:Int,c2:Int):String {
		mutex.acquire();var out:Array<String> = [];
		for (r in Std.int(Math.max(0,r1))...Std.int(Math.min(copies.length,r2+1))) {
			var line = copies[r];if (line == null) continue;
			var from = r == r1 ? c1 : 0,to = r == r2 ? c2 : grid.cols;
			from = Std.int(Math.max(0,Math.min(grid.cols,from)));to = Std.int(Math.max(from,Math.min(grid.cols,to)));
			out.push(StringTools.rtrim(line.text.substring(line.columns.getUInt16(from*2),line.columns.getUInt16(to*2))));
		}
		mutex.release();return out.join("\n");
	}
	public function close():Void {
		mutex.acquire();if (closed) {mutex.release();return;}var id = handle;closed = true;pending = "";rows = [];copies = [];dirty.clear();mutex.release();
		unsubscribe();if (id >= 0 && generation == client.connectionEpoch()) try client.notify("term.close",{tid:id,sessionGeneration:generation}) catch (_:Dynamic) {}
	}
}
