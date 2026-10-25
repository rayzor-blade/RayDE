package rayde.workspace;

/** Where RayDE's programs run: on this machine, or in a session beside the workspace's files. */
interface Launcher {
	/** Starts `command` with `args`. Throws when it cannot be started. */
	function start(command:String, args:Array<String>):Program;
}
