import rayde.lang.CompilerServer;

/**
 * A compilation server must not outlive the process that started it. The stand-in compiler below records its pid and sleeps;
 * closing the server's stdin is what the system does when its owner dies, however it dies.
 */
class CompilerServerLifetimeChecks {
	static function check(ok:Bool, message:String):Void if (!ok) throw message;

	static function alive(pid:Int):Bool
		return Sys.command("sh", ["-c", "kill -0 " + pid + " 2>/dev/null"]) == 0;

	/** Waits up to three seconds for `done`. */
	static function until(done:Void->Bool):Bool {
		var end = haxe.Timer.stamp() + 3;
		while (haxe.Timer.stamp() < end) {
			if (done()) return true;
			Sys.sleep(.02);
		}
		return done();
	}

	static function compiler(dir:String, body:String):String {
		var path = dir + "/fake-haxe";
		sys.io.File.saveContent(path, "#!/bin/sh\necho $$ > " + dir + "/pid\n" + body + "\n");
		Sys.command("chmod", ["+x", path]);
		return path;
	}

	static function pidOf(dir:String):Int {
		check(until(() -> sys.FileSystem.exists(dir + "/pid") && StringTools.trim(sys.io.File.getContent(dir + "/pid")) != ""), "The stand-in compiler never started");
		return Std.parseInt(StringTools.trim(sys.io.File.getContent(dir + "/pid")));
	}

	static function main():Void {
		if (Sys.systemName() == "Windows") {
			Sys.println("Compilation server lifetime: skipped on Windows");
			return;
		}
		var dir = Sys.getCwd() + "bin/server-lifetime-" + Std.random(0x3fffffff);
		sys.FileSystem.createDirectory(dir);
		var leftovers:Array<Int> = [];
		try {
			// Stopping the server ends the compiler.
			var server = compiler(dir, "exec sleep 300");
			var p = CompilerServer.launch(server, 7699);
			var pid = pidOf(dir);
			leftovers.push(pid);
			check(alive(pid), "The compiler is not running");
			p.kill();
			p.close();
			check(until(() -> !alive(pid)), "Stopping the server left the compiler running");

			// The owner going away (its end of the stdin pipe closing) ends the compiler, though nothing stops the server.
			sys.FileSystem.deleteFile(dir + "/pid");
			var p = CompilerServer.launch(server, 7699);
			var pid = pidOf(dir);
			leftovers.push(pid);
			check(alive(pid), "The compiler is not running");
			p.stdin.close();
			check(until(() -> !alive(pid)), "The compiler outlived its owner");
			check(until(() -> p.exitCode(false) != null), "The holder outlived the compiler it held");
			p.kill();
			p.close();

			// A compiler that dies by itself is seen as stopped, not held open until its owner goes.
			sys.FileSystem.deleteFile(dir + "/pid");
			var crash = compiler(dir, "exit 3");
			var p = CompilerServer.launch(crash, 7699);
			check(until(() -> p.exitCode(false) != null), "A compiler that exited was still reported as running");
			p.kill();
			p.close();
		} catch (error:Dynamic) {
			for (pid in leftovers) if (alive(pid)) Sys.command("kill", [Std.string(pid)]);
			Sys.command("rm", ["-rf", dir]);
			throw error;
		}
		Sys.command("rm", ["-rf", dir]);
		Sys.println("Compilation server lifetime: stopping ends the compiler, so does its owner going away, and a compiler that exits is seen as stopped");
	}
}
