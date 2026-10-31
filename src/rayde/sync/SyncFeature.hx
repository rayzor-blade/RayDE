package rayde.sync;

import ashui.layout.Element;
import ashui.reactive.Signal;
import rayde.sync.SyncState;
import rayde.ui.Contributions;
import rayde.ui.Host;
import rayde.ui.Icons;
import rayde.ui.SyncPanel;

/**
	Cloud Sync as a feature: its icon in the activity bar, its command and its side panel. For now it shows what stands between this folder and a sync
	(not a Git repository, nobody signed in) and the rest of the states the panel can show; the actions that need the account and the gateway say so.
**/
class SyncFeature {
	final host:Host;
	static final installed = new haxe.ds.ObjectMap<Contributions, SyncFeature>();
	public final state = Signal.make(Sync.empty(SignedOut));

	public static function install(host:Host):Void
		installed.set(host.contributions, new SyncFeature(host));

	/** The Cloud Sync feature of a workbench, for tests and tools that look at it. */
	public static function of(contributions:Contributions):Null<SyncFeature>
		return installed.get(contributions);

	function new(host:Host) {
		this.host = host;
		var c = host.contributions;
		c.command({id:"cloudsync.open", label:"Cloud Sync: Open Panel", icon:Icons.UPLOAD_CLOUD_2_FILL, run:show});
		c.activity({id:"rayde-activity-sync", title:"Cloud Sync", icon:Icons.UPLOAD_CLOUD_2_FILL, order:60, on:() -> host.sidebarShown("sync"),
			run:() -> if (host.sidebarShown("sync")) host.hideSidebar() else show()});
		c.sidebar("sync", panel);
		c.onClose(() -> installed.remove(c));
		refresh();
	}

	public function show():Void {
		refresh();
		host.showSidebar("sync");
	}

	/**
		Looks at the folder again: a Git repository or not, and its branch. Sign-in is not available yet, so an eligible folder waits on it.
		`RAYDE_SYNC_SAMPLE=<phase>` shows the panel in any phase with made-up numbers, for looking at the design.
	**/
	public function refresh():Void {
		var sample = Sys.getEnv("RAYDE_SYNC_SAMPLE");
		if (sample != null && sample != "") {
			state.set(sampleOf(sample));
			return;
		}
		#if wasm
		return;
		#else
		var branch = branchOf(host.cwd);
		var next = Sync.empty(branch == null ? NoGit : SignedOut);
		next.branch = branch ?? "";
		state.set(next);
		#end
	}

	function panel():Element
		return <sync-panel workspace={host.name} state={state} now={() -> Date.now().getTime()}
			unavailableMessage={#if wasm "Cloud Sync starts from the desktop app. A synced workspace opens in the browser from its link." #else null #end}
			onSignIn={() -> host.say("Signing in to rayde.org is not available yet.")} onInitGit={initGit}
			onSync={unavailable} onCancel={unavailable} onRetry={unavailable} onCopy={unavailable} onOpen={unavailable} onShare={unavailable} onPause={unavailable}
			onExport={unavailable} onExtend={unavailable} onDisconnect={unavailable} onDelete={unavailable}
			onExpiry={hours -> { var s = state.get(); state.set({phase:s.phase, branch:s.branch, files:s.files, bytes:s.bytes, excluded:s.excluded, allocation:s.allocation, expiryHours:hours,
				sent:s.sent, total:s.total, url:s.url, lastSync:s.lastSync, used:s.used, expiresAt:s.expiresAt, compute:s.compute, message:s.message, conflicts:s.conflicts}); }}/>;

	/**
		Asks the Git extension to initialize a repository in the workspace folder, as the person's own act; it uses the libgit2 RayDE bundles, so no
		`git` program is needed. The extension answers a moment later, so the folder is looked at again until it is a repository. The sync never does this by itself.
	**/
	public function initGit():Void {
		if (!host.extensionCommand("git", "git.initialize")) {
			host.say("Initializing a repository needs the Git extension, which is not available.");
			return;
		}
		var looks = 0;
		function look():Void {
			refresh();
			if (host.closed() || state.get().phase != NoGit || ++looks > 30) return;
			ashui.animation.AnimationScheduler.main.after(.5, look);
		}
		ashui.animation.AnimationScheduler.main.after(.25, look);
	}

	function unavailable():Void
		host.say("Cloud Sync is not available yet.");

	/** The current branch of a Git working tree, "" for an unborn repository, or null when the folder is not one. A linked worktree's `.git` is a file that points at its own. */
	public static function branchOf(folder:String):Null<String> {
		#if wasm
		return null;
		#else
		var dot = folder + "/.git";
		if (!sys.FileSystem.exists(dot)) return null;
		var gitdir = dot;
		if (!sys.FileSystem.isDirectory(dot)) {
			var pointer = StringTools.trim(sys.io.File.getContent(dot));
			if (!StringTools.startsWith(pointer, "gitdir:")) return null;
			gitdir = StringTools.trim(pointer.substr(7));
			if (!haxe.io.Path.isAbsolute(gitdir)) gitdir = haxe.io.Path.join([folder, gitdir]);
		}
		var head = gitdir + "/HEAD";
		if (!sys.FileSystem.exists(head)) return null;
		var text = StringTools.trim(sys.io.File.getContent(head));
		var prefix = "ref: refs/heads/";
		if (StringTools.startsWith(text, prefix)) {
			var branch = text.substr(prefix.length);
			return sys.FileSystem.exists(gitdir + "/refs/heads/" + branch) || packed(gitdir, branch) ? branch : "";
		}
		return text.length >= 7 ? "detached " + text.substr(0, 7) : "";
		#end
	}

	#if !wasm
	static function packed(gitdir:String, branch:String):Bool {
		var file = gitdir + "/packed-refs";
		return sys.FileSystem.exists(file) && sys.io.File.getContent(file).indexOf(" refs/heads/" + branch + "\n") >= 0;
	}
	#end

	/** Made-up numbers for a phase, to look at the panel's design. */
	public static function sampleOf(name:String):SyncState {
		var now = Date.now().getTime(), hour = 3600000.;
		var phase:SyncPhase = switch name {
			case "signed-out" | "no-git" | "ready" | "checking" | "uploading" | "verifying" | "synced" | "pending" | "conflict" | "failed" | "expiring" | "expired" | "deleting": cast name;
			case _: Ready;
		};
		var s = Sync.empty(phase);
		s.branch = "main";
		s.files = 412;
		s.bytes = 18.4e6;
		s.excluded = 37;
		s.sent = 11.2e6;
		s.total = 18.4e6;
		s.url = "https://app.rayde.org/wX3q7Vb2LhA9kqP0sYtZmN4cDeF8uRjG1oIaB5xT6Kc";
		s.lastSync = now - 7 * 60000;
		s.used = 21.6e6;
		s.expiresAt = now + 22.5 * hour;
		s.compute = "sleeping";
		switch phase {
			case Expiring: s.expiresAt = now + 0.75 * hour;
			case Expired: s.expiresAt = now - hour;
			case Failed: s.message = "The connection dropped while uploading. Check your network and retry.";
			case Conflict: s.conflicts = 2; s.message = "src/Main.hx and README.md changed on this device and in the browser.";
			case _:
		}
		return s;
	}
}
