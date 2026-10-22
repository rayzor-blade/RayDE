import rayde.run.Job;
import rayde.run.OutputJobs;
import rayde.run.Worker;

class PanelWorkerChecks {
	static function main():Void run();
	static function until(done:Void->Bool, message:String):Void {
		var end = haxe.Timer.stamp() + 10;
		while (!done() && haxe.Timer.stamp() < end) Sys.sleep(.005);
		if (!done()) throw message;
	}

	public static function run():Void {
		var entered = new sys.thread.Lock(), release = new sys.thread.Lock();
		var worker = new Worker<Int, Int>((value, cancelled) -> {
			if (value == 1) { entered.release(); release.wait(); }
			return value;
		});
		worker.submit("file", 1);
		if (!entered.wait(5)) throw "Panel worker did not start";
		for (i in 2...100) worker.submit("file", i);
		worker.submit("closed", 100); worker.cancel("closed");
		release.release();
		var results = [];
		until(() -> { results = results.concat(worker.poll()); return !worker.busy(); }, "Panel worker did not settle");
		if (results.length != 1 || results[0].value != 99) throw "Panel worker delivered superseded or cancelled results";
		worker.dispose(); worker.submit("disposed", 1);
		if (worker.busy()) throw "Disposed panel worker accepted work";

		var logs = new OutputJobs();
		logs.request("ext", ["first\r\nsecond\rthird"], ["error"]);
		var formatted = [];
		until(() -> { formatted = formatted.concat(logs.poll()); return !logs.busy(); }, "Output normalization did not finish");
		if (formatted.length != 1 || formatted[0].value.text != "first\nsecond\nthird" || formatted[0].value.kinds.join(",") != "error,error,error")
			throw "Output worker lost line endings or severity";
		logs.request("ext", [[for (i in 0...3000) 'line $i'].join("\n")], ["warning"]);
		formatted = [];
		until(() -> { formatted = formatted.concat(logs.poll()); return !logs.busy(); }, "Large output normalization did not finish");
		if (formatted[0].value.kinds.length != 2000 || !StringTools.startsWith(formatted[0].value.text, "line 1000\n"))
			throw "Output worker did not bound the visible cache";
		logs.request("stream", ["first"], ["info"]);
		var delivered = [];
		// Keep a newer snapshot queued on every poll while still accepting completed work.
		for (i in 0...200) {
			logs.request("stream", ['update $i'], ["info"]);
			delivered = delivered.concat(logs.poll());
			Sys.sleep(.002);
		}
		if (delivered.length == 0) throw "Continuous Output updates starved the view";
		until(() -> { delivered = delivered.concat(logs.poll()); return !logs.busy(); }, "Output stream did not settle");
		if (delivered[delivered.length - 1].value.text != "update 199") throw "Output stream lost its latest snapshot";
		logs.dispose();

		var log = Sys.getCwd() + "bin/check-output-worker.log";
		var job = new Job("/bin/sh", ["-c", "printf 'first\\n'; sleep .1; printf 'last\\n'; exit 7"], log, null, null, true);
		job.start();
		var text = "";
		until(() -> { text += job.read(); return !job.running(); }, "Output worker did not finish the process");
		text += job.read();
		if (job.exit != 7 || text != "first\nlast\n") throw "Output worker lost output or exit status: " + text;
		var marker = Sys.getCwd() + "bin/check-output-cancelled";
		if (sys.FileSystem.exists(marker)) sys.FileSystem.deleteFile(marker);
		var stopped = new Job("/bin/sh", ["-c", "sleep .2; touch '" + marker + "'"], log, null, null, true);
		stopped.start(); stopped.stop();
		until(() -> !stopped.running(), "Cancelled output worker did not stop");
		Sys.sleep(.25);
		if (sys.FileSystem.exists(marker)) throw "Cancelled output worker left its process running";
		var terminal = rayde.term.Terminal.open(80, 8, Sys.getCwd(), "/bin/sh", ["-c", "read value; printf 'accepted:%s\\n' \"$value\"; read wait"], true);
		if (terminal == null || !terminal.write("queued\n")) throw "Starting terminal rejected input";
		until(() -> { terminal.starting(); return terminal.line(1).indexOf("accepted:queued") >= 0; }, "Starting terminal lost queued input");
		terminal.close();
		Sys.println("panel workers: coalescing, cancellation, bounded severity logs, process output and exit status");
	}
}
