package rayde.run;

/**
 * Installs, updates and removes haxelib libraries, one at a time in the background, and says what is going
 * on. The Libraries page draws from it and polls it; it keeps its state when the page is made again.
 */
class LibraryManager {
	public final root:String;

	/** What the running job does, such as "Installing tink_macro"; empty when none runs. */
	public var doing(default, null) = "";

	/** How the last job ended; empty before there was one. */
	public var message(default, null) = "";

	public var failed(default, null) = false;

	/** Changes each time a job starts or ends. */
	public var revision(default, null) = 0;

	var job:Null<Job>;
	var done = "";

	public function new(root:String)
		this.root = root;

	public function busy():Bool
		return job != null;

	public function install(name:String, version = ""):Void
		start(Haxelib.install(root, name, version), 'Installing $name', 'Installed $name');

	public function update(name:String):Void
		start(Haxelib.update(root, name), 'Updating $name', 'Updated $name');

	public function remove(name:String):Void
		start(Haxelib.remove(root, name), 'Removing $name', 'Removed $name');

	function start(next:Job, what:String, finished:String):Void {
		if (job != null)
			return;
		next.start();
		job = next;
		doing = what;
		done = finished;
		message = "";
		failed = false;
		revision++;
	}

	/** Looks at the job; true when it has just ended, with `message` saying how and the library list asked for again. */
	public function tick():Bool {
		if (job == null || job.running())
			return false;
		var text = StringTools.trim(job.read()), lines = text.split("\n");
		failed = job.exit != 0;
		message = failed ? "haxelib failed" + (text == "" ? "" : ": " + StringTools.trim(lines[lines.length - 1])) : done;
		job = null;
		doing = "";
		Haxelib.refresh();
		revision++;
		return true;
	}
}
