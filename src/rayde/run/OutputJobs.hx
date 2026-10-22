package rayde.run;

private typedef Request = {lines:Array<String>, kinds:Array<String>};
typedef OutputSnapshot = AnsiOutput.AnsiSnapshot;

/** A burst replaces pending work per channel; completed snapshots still arrive during a continuous stream. */
class OutputJobs {
	final worker = new Worker<Request, OutputSnapshot>(format);
	final active = new Map<String, Bool>();
	final pending = new Map<String, Request>();

	public function new() {}
	public function request(channel:String, lines:Array<String>, kinds:Array<String>):Void {
		var request = {lines:lines.copy(), kinds:kinds == null ? null : kinds.copy()};
		if (active.exists(channel)) pending.set(channel, request);
		else { active.set(channel, true); worker.submit(channel, request); }
	}
	public function busy():Bool return worker.busy();
	public function poll():Array<rayde.run.Worker.WorkerResult<OutputSnapshot>> {
		var results = worker.poll();
		for (result in results) {
			active.remove(result.key);
			var next = pending.get(result.key);
			if (next != null) {
				pending.remove(result.key);
				active.set(result.key, true);
				worker.submit(result.key, next);
			}
		}
		return results;
	}
	public function dispose():Void { pending.clear(); active.clear(); worker.dispose(); }

	static function format(request:Request, cancelled:Void->Bool):OutputSnapshot {
		var decoder = new AnsiOutput();
		for (i in 0...request.lines.length) {
			if (cancelled()) break;
			if (i > 0) decoder.write("\n");
			decoder.write(request.lines[i], request.kinds == null ? null : request.kinds[i]);
		}
		return decoder.snapshot();
	}
}
