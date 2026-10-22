package rayde;

/** Starts Welcome or a command-line workspace in the desktop window manager. */
class Main {
	static function main():Void {
		var args = Sys.args();
		rayde.ui.ProjectWindows.run(args.length == 0 ? null : args[0]);
	}
}
