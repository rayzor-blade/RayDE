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
	/** The running upload's handle in the native client, or -1. */
	var push = -1;

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
		if (push >= 0) return;
		var branch = branchOf(host.cwd);
		var next = Sync.empty(branch == null ? NoGit : account() == null ? SignedOut : Ready);
		next.branch = branch ?? "";
		state.set(next);
		#end
	}

	function panel():Element
		return <sync-panel workspace={host.name} state={state} now={() -> Date.now().getTime()}
			unavailableMessage={#if wasm "Cloud Sync starts from the desktop app. A synced workspace opens in the browser from its link." #else null #end}
			onSignIn={() -> host.say("Signing in to rayde.org is not available yet.")} onInitGit={initGit}
			onSync={sync} onCancel={cancel} onRetry={sync} onCopy={unavailable} onOpen={unavailable} onShare={unavailable} onPause={unavailable}
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

	/** Where the gateway is, from `RAYDE_SYNC_GATEWAY`; null until a hosted one exists to default to. */
	static function gateway():Null<String> {
		var url = Sys.getEnv("RAYDE_SYNC_GATEWAY");
		return url == null || url == "" ? null : url;
	}

	/** The development account of a gateway running on this machine, which has no GitHub App to sign in with. */
	static function account():Null<String> {
		var name = Sys.getEnv("RAYDE_SYNC_DEV_ACCOUNT");
		return gateway() == null || name == null || name == "" ? null : name;
	}

	/** Uploads the folder through the native client and follows its events until it publishes, fails or is cancelled. */
	public function sync():Void {
		#if !wasm
		if (push >= 0) return;
		var url = gateway();
		if (url == null || state.get().phase == NoGit) {
			host.say(url == null ? "Set RAYDE_SYNC_GATEWAY to a gateway to sync with." : "Cloud Sync needs a Git repository.");
			return;
		}
		var before = state.get();
		var running = Sync.empty(Checking);
		running.branch = before.branch;
		state.set(running);
		try {
			push = NativeSync.start({root: host.cwd, gateway: url, account: account(), device: host.name});
		} catch (error) {
			failed(Std.string(error));
			return;
		}
		follow();
		#end
	}

	public function cancel():Void {
		#if !wasm
		if (push >= 0) NativeSync.cancel(push);
		#end
	}

	#if !wasm
	function follow():Void {
		var id = push;
		var events = NativeSync.poll(id);
		var current = state.get();
		if (events != null) for (event in events) {
			switch (event.event) {
				case "workspace": current.url = event.url;
				case "scanned":
					current.phase = Uploading;
					current.files = event.files;
					current.bytes = event.bytes;
					current.excluded = event.omitted;
				case "upload":
					current.sent = event.bytes;
					current.total = event.bytesTotal;
				case "published":
					current.phase = Synced;
					current.url = event.url;
					current.lastSync = Date.now().getTime();
					current.used = event.stored;
					current.expiresAt = event.expiresAt == null ? 0 : event.expiresAt;
				case "error":
					if (event.code == "cancelled") current.phase = Ready else {
						current.phase = Failed;
						current.message = event.message;
					}
			}
		}
		state.set({phase:current.phase, branch:current.branch, files:current.files, bytes:current.bytes, excluded:current.excluded, allocation:current.allocation,
			expiryHours:current.expiryHours, sent:current.sent, total:current.total, url:current.url, lastSync:current.lastSync, used:current.used,
			expiresAt:current.expiresAt, compute:current.compute, message:current.message, conflicts:current.conflicts});
		if (NativeSync.pending(id) && !host.closed()) {
			ashui.animation.AnimationScheduler.main.after(.2, follow);
			return;
		}
		NativeSync.close(id);
		push = -1;
	}

	function failed(message:String):Void {
		var s = Sync.empty(Failed);
		s.branch = state.get().branch;
		s.message = message;
		state.set(s);
	}
	#end

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
