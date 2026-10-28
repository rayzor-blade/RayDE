package rayde.run;

/** A bounded mailbox for compiler readers; only the UI poll publishes reactive state. */
class BuildProgress {
	final mutex = new sys.thread.Mutex();
	var phase = "Preparing preview";
	var output = "";
	var revision = 0;
	public function new() {}
	public function stage(value:String):Void {
		mutex.acquire(); phase = value; mutex.release();
		append(value + "…\n");
	}
	public function append(value:String):Void {
		mutex.acquire();
		output += value;
		if (output.length > 512 * 1024) output = output.substr(output.length - 512 * 1024);
		revision++;
		mutex.release();
	}
	public function snapshot():{phase:String, output:String, revision:Int} {
		mutex.acquire();
		var value = {phase:phase, output:output, revision:revision};
		mutex.release(); return value;
	}
}
