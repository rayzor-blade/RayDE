package rayde.ui;

import rayde.run.Job;
import ashui.animation.AnimationScheduler;
import ashui.reactive.Owner;

/** A mounted panel's single background request; replacement and disposal discard late replies. */
class ExplorerJob {
	final base:String;
	final root:String;
	var job:Null<Job>;
	var serial = 0;
	var live = true;

	public function new(root:String) {
		this.root = root;
		base = root + "/.rayde/explorer/" + Std.string(haxe.Timer.stamp()).split(".").join("-");
		Owner.onCleanup(() -> { live = false; cancel(); });
	}

	public function cancel():Void {
		serial++;
		if (job != null) job.stop();
		job = null;
		for (suffix in [".log", ".input"]) if (sys.FileSystem.exists(base + suffix)) sys.FileSystem.deleteFile(base + suffix);
	}

	public function run(command:String, args:Array<String>, done:(Int, String)->Void, ?input:String):Void {
		cancel();
		var request = serial;
		// Debounce buffer changes before starting the compiler.
		AnimationScheduler.main.after(.18, () -> {
			if (!live || request != serial) return;
			try {
				sys.FileSystem.createDirectory(haxe.io.Path.directory(base));
				if (input != null) sys.io.File.saveContent(base + ".input", input);
				job = new Job(command, args, base + ".log", input == null ? null : base + ".input", root);
				job.start();
				function poll():Void {
					if (!live || request != serial || job == null) return;
					if (job.running()) { AnimationScheduler.main.after(.03, poll); return; }
					var code = job.exit, text = job.read();
					job = null;
					for (suffix in [".log", ".input"]) if (sys.FileSystem.exists(base + suffix)) sys.FileSystem.deleteFile(base + suffix);
					done(code, text);
				}
				poll();
			} catch (error:Dynamic) { cancel(); if (live) done(-1, Std.string(error)); }
		});
	}
}
