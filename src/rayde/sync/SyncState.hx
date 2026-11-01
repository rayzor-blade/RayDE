package rayde.sync;

/** Where a workspace stands with Cloud Sync. Storage sync and compute are separate: `compute` below says what the cloud copy's sandbox is doing. */
enum abstract SyncPhase(String) to String {
	/** The folder is a Git working tree but nobody is signed in. */
	var SignedOut = "signed-out";
	/** The folder is not a Git repository. Initializing one is a separate act. */
	var NoGit = "no-git";
	/** Eligible: the preflight shows what a sync would send. */
	var Ready = "ready";
	var Checking = "checking";
	var Uploading = "uploading";
	var Verifying = "verifying";
	var Synced = "synced";
	/** Offline, with changes waiting for the connection. */
	var Pending = "pending";
	var Conflict = "conflict";
	var Failed = "failed";
	var Expiring = "expiring";
	var Expired = "expired";
	var Deleting = "deleting";
}

/** Everything the Cloud Sync panel shows. Bytes are decimal: 1 GB is 1,000,000,000. Times are milliseconds since the epoch, from the server where they come from it. */
/** A file both sides edited in the same place, and which side's version was picked for it: "mine", "theirs" or "" while undecided. */
typedef ConflictItem = {path:String, reason:String, choice:String};

typedef SyncState = {
	phase:SyncPhase,
	branch:String,
	/** The preflight: files and bytes a sync would send, and what the selection leaves out. */
	files:Int,
	bytes:Float,
	excluded:Int,
	allocation:Float,
	/** How long the cloud copy lives from its first sync, as chosen. */
	expiryHours:Int,
	/** Progress of an upload. */
	sent:Float,
	total:Float,
	/** The workspace's link, once published: `https://app.rayde.org/{id}`. */
	url:String,
	lastSync:Float,
	used:Float,
	expiresAt:Float,
	/** "none", "starting", "running" or "sleeping". */
	compute:String,
	/** What went wrong, for Failed, or what conflicts, for Conflict. */
	message:String,
	conflicts:Int,
	/** The files behind `conflicts`, with the picks made so far. */
	?items:Array<ConflictItem>
};

class Sync {
	public static function empty(phase:SyncPhase):SyncState
		return {
			phase: phase, branch: "", files: 0, bytes: 0, excluded: 0, allocation: 1e9, expiryHours: 24, sent: 0, total: 0, url: "", lastSync: 0, used: 0,
			expiresAt: 0, compute: "none", message: "", conflicts: 0
		};

	/** Whether the phase is one where a sync is under way and can be cancelled. */
	public static function busy(phase:SyncPhase):Bool
		return phase == Checking || phase == Uploading || phase == Verifying;

	/** Whether the cloud copy exists, so it can be opened, shared, extended or deleted. */
	public static function published(phase:SyncPhase):Bool
		return phase == Synced || phase == Pending || phase == Conflict || phase == Expiring;

	/** Sizes the way the plan states them: decimal units, one decimal at most. */
	public static function bytes(value:Float):String {
		inline function one(v:Float, unit:String):String {
			var tenths = Math.round(v * 10) / 10;
			return (tenths == Math.floor(tenths) ? Std.string(Std.int(tenths)) : Std.string(tenths)) + " " + unit;
		}
		if (value >= 1e9) return one(value / 1e9, "GB");
		if (value >= 1e6) return one(value / 1e6, "MB");
		if (value >= 1e3) return one(value / 1e3, "KB");
		return Std.int(value) + " B";
	}

	/** Time left, as the panel says it: "23 h 40 min", "12 min", "less than a minute", or "Expired". */
	public static function remaining(ms:Float):String {
		if (ms <= 0) return "Expired";
		var minutes = Math.floor(ms / 60000), hours = Math.floor(minutes / 60), days = Math.floor(hours / 24);
		if (days >= 2) return days + " days";
		if (hours >= 1) return hours + " h " + (minutes % 60) + " min";
		if (minutes >= 1) return minutes + " min";
		return "less than a minute";
	}

	/** A duration chosen for the expiry, as the menu words it. */
	public static function hours(value:Int):String
		return value % 24 == 0 && value >= 48 ? Std.int(value / 24) + " days" : value == 1 ? "1 hour" : value + " hours";

	/** How long ago, for the last sync: "just now", "5 min ago", "3 h ago", "2 days ago". */
	public static function ago(ms:Float):String {
		var minutes = Math.floor(ms / 60000);
		if (minutes < 1) return "just now";
		if (minutes < 60) return minutes + " min ago";
		var hours = Math.floor(minutes / 60);
		return hours < 48 ? hours + " h ago" : Math.floor(hours / 24) + " days ago";
	}

	/** The share of an upload done, from 0 to 1. */
	public static function progress(state:SyncState):Float
		return state.total <= 0 ? 0 : Math.min(1, state.sent / state.total);
}
