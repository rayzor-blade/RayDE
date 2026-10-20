package rayde.ext;

/** Opt-in extension UI timing; safe to enable with RAYDE_EXTENSION_TIMING=1. */
class Timing {
	public static final enabled = Sys.getEnv("RAYDE_EXTENSION_TIMING") == "1";
	public static inline function start():Float return enabled ? haxe.Timer.stamp() : 0.;
	public static function end(start:Float, stage:String, ?detail:Dynamic):Void {
		if (!enabled) return;
		var ms = (haxe.Timer.stamp() - start) * 1000;
		if (ms >= 1) Sys.println("extension-timing:" + haxe.Json.stringify({thread:"ui", stage:stage, ms:ms, detail:detail, at:Sys.time()}));
	}
}
