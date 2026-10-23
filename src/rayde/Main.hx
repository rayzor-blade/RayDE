package rayde;

/** Starts a command-line workspace or resumes the desktop window session. */
class Main {
	static function main():Void {
		var args = Sys.args();
		rayde.ui.ProjectWindows.run(args.length == 0 ? null : args[0]);
	}
}
