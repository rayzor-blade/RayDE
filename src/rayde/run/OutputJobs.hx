package rayde.run;

private typedef Request = {lines:Array<String>, kinds:Array<String>};
typedef OutputSnapshot = {text:String, kinds:Array<String>};

/** A burst replaces pending work per channel; completed snapshots still arrive during a continuous stream. */
class OutputJobs {
	final worker = new Worker<Request, OutputSnapshot>(format);
	final active = new Map<String, Bool>();
	final pending = new Map<String, Request>();

	public function new() {}
	public function request(channel:String, lines:Array<String>, kinds:Array<String>):Void {
		var request = {lines:lines.copy(), kinds:kinds.copy()};
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
		var lines:Array<String> = [], kinds:Array<String> = [];
		// Walk backwards so a single large log record cannot grow the visible cache without bound.
		var i = request.lines.length, endings = ~/\r\n|\r/g;
		while (i > 0 && lines.length < 2000 && !cancelled()) {
			--i;
			var record = endings.replace(request.lines[i], "\n").split("\n"), at = record.length;
			while (at > 0 && lines.length < 2000) { lines.push(record[--at]); kinds.push(request.kinds[i]); }
		}
		lines.reverse(); kinds.reverse();
		return {text:lines.join("\n"), kinds:kinds};
	}
}
