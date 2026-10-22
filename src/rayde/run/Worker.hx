package rayde.run;

private typedef Task<T> = {key:String, serial:Int, value:T};
typedef WorkerResult<T> = {key:String, value:Null<T>, error:Null<String>};

private class Mailbox<T, R> {
	public final mutex = new sys.thread.Mutex();
	public final wake = new sys.thread.Lock();
	public final pending = new Map<String, Task<T>>();
	public final order:Array<String> = [];
	public final versions = new Map<String, Int>();
	public final results = new Map<String, WorkerResult<R>>();
	public var serial = 0;
	public var stopped = false;
	public var started = false;
	public var active:Null<Task<T>>;
	public function new() {}

	public function current(task:Task<T>):Bool {
		mutex.acquire();
		var current = !stopped && versions.get(task.key) == task.serial;
		mutex.release();
		return current;
	}
}

/** A data-only worker with one pending request and one result per key. UI owners never enter its closure. */
class Worker<T, R> {
	static inline var IDLE_SECONDS = 1.;
	final mailbox = new Mailbox<T, R>();
	final work:(T, Void->Bool)->R;

	public function new(work:(T, Void->Bool)->R) this.work = work;

	public function submit(key:String, value:T):Void {
		var box = mailbox;
		box.mutex.acquire();
		if (box.stopped) { box.mutex.release(); return; }
		var start = !box.started, wake = !box.pending.exists(key);
		box.started = true;
		box.versions.set(key, ++box.serial);
		box.results.remove(key);
		if (wake) box.order.push(key);
		box.pending.set(key, {key:key, serial:box.serial, value:value});
		box.mutex.release();
		if (start) {
			var handler = work;
			sys.thread.Thread.create(() -> run(box, handler));
		}
		if (wake) box.wake.release();
	}

	public function cancel(key:String):Void {
		mailbox.mutex.acquire();
		mailbox.versions.remove(key);
		mailbox.pending.remove(key);
		mailbox.order.remove(key);
		mailbox.results.remove(key);
		mailbox.mutex.release();
	}

	public function busy():Bool {
		mailbox.mutex.acquire();
		var busy = mailbox.active != null || mailbox.order.length > 0 || Lambda.count(mailbox.results) > 0;
		mailbox.mutex.release();
		return busy;
	}

	/** Transfers completed data to the caller; it never waits for work to finish. */
	public function poll():Array<WorkerResult<R>> {
		mailbox.mutex.acquire();
		var results = [for (result in mailbox.results) result];
		mailbox.results.clear();
		mailbox.mutex.release();
		return results;
	}

	/** Cancels outstanding work without joining the worker on the UI thread. */
	public function dispose():Void {
		mailbox.mutex.acquire();
		mailbox.stopped = true;
		mailbox.pending.clear(); mailbox.order.resize(0);
		mailbox.versions.clear(); mailbox.results.clear();
		mailbox.mutex.release();
		mailbox.wake.release();
	}

	static function run<T, R>(box:Mailbox<T, R>, work:(T, Void->Bool)->R):Void {
		while (true) {
			var woke = box.wake.wait(IDLE_SECONDS);
			box.mutex.acquire();
			// Retire under the submit lock so the next request either reaches this worker or starts its successor.
			if (box.stopped || !woke && box.order.length == 0) {
				box.started = false;
				box.mutex.release();
				return;
			}
			var key = box.order.shift(), task = key == null ? null : box.pending.get(key);
			if (key != null) box.pending.remove(key);
			box.active = task;
			box.mutex.release();
			if (task == null) continue;
			perform(box, task, work);
			task = null;
		}
	}

	static function perform<T, R>(box:Mailbox<T, R>, task:Task<T>, work:(T, Void->Bool)->R):Void {
		var value:Null<R> = null, error:Null<String> = null;
		try value = work(task.value, () -> !box.current(task)) catch (failure:Dynamic) error = Std.string(failure);
		box.mutex.acquire();
		if (!box.stopped && box.versions.get(task.key) == task.serial)
			box.results.set(task.key, {key:task.key, value:value, error:error});
		box.active = null;
		box.mutex.release();
	}
}
