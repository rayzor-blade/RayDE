package rayde.ui;

import ashui.components.Badge;
import ashui.components.Button;
import ashui.components.DropdownMenu;
import ashui.components.Icon;
import ashui.components.Progress;
import ashui.components.Select;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.sync.SyncState;
import rayde.sync.SyncState.ConflictItem;
import rayde.sync.SyncState.Sync;

/** What the panel shows in a browser session that is a restored copy of a cloud workspace: which generation it is a copy of, and how the last save went. */
typedef SaveBack = {generation:Int, busy:Bool, message:String, failed:Bool, canMerge:Bool, conflicts:Array<ConflictItem>};

typedef SyncPanelProps = {
	workspace:String,
	state:Signal<SyncState>,
	/** The current time in milliseconds, for the time left. */
	now:Void->Float,
	?unavailableMessage:String,
	?saveBack:Signal<Null<SaveBack>>,
	?onSave:Void->Void,
	?onMerge:Void->Void,
	onPull:Void->Void,
	/** Settles the files both sides edited in the same place: "mine" keeps the local file, "theirs" takes the remote one. */
	onResolve:String->Void,
	/** Picks a side for one file: "mine" or "theirs". */
	onPick:(String, String) -> Void,
	/** Settles the files with the picks made; only offered once every file has one. */
	onApply:Void->Void,
	/** Opens a conflicted file as local against remote. */
	onDiff:String->Void,
	onSignIn:Void->Void,
	onInitGit:Void->Void,
	onSync:Void->Void,
	onCancel:Void->Void,
	onRetry:Void->Void,
	onCopy:Void->Void,
	onOpen:Void->Void,
	onShare:Void->Void,
	onPause:Void->Void,
	onExport:Void->Void,
	onExtend:Void->Void,
	onDisconnect:Void->Void,
	onDelete:Void->Void,
	onExpiry:Int->Void
};

/** Cloud Sync's side panel: what a sync would send and what the cloud copy is, in the states the plan names. It does nothing itself; the feature supplies the state and the actions. */
class SyncPanel extends Component<SyncPanelProps> {
	function render():Element
		return <div id="rayde-sync-panel" class="flex flex-col flex-1 min-w-0 min-h-0">
		<div class="rayde-sync-heading">
			<icon document={Icons.UPLOAD_CLOUD_2_FILL} class="size-4 shrink-0"/><text class="flex-1">Cloud Sync</text>
			<if {props.saveBack == null || props.saveBack.get() == null}><for {state in [props.state.get()]}>${phaseBadge(state)}</for></if>
		</div>
		<div class="rayde-sync-scroll">
			<text id="rayde-sync-workspace" class="rayde-sync-workspace">${props.workspace}</text>
			<if {props.saveBack != null && props.saveBack.get() != null}>
				<for {saved in [props.saveBack.get()]}>${saveBack(saved)}</for>
			<else>
				<if {props.unavailableMessage != null}>
					<div class="rayde-sync-section"><text id="rayde-sync-unavailable" class="rayde-sync-muted">${props.unavailableMessage}</text></div>
				<else>
					<for {state in [props.state.get()]}>${body(state)}</for>
				</if>
			</if>
		</div>
	</div>;

	function phaseBadge(state:SyncState):Element {
		var label = switch state.phase {
			case SignedOut: "Signed out";
			case NoGit: "Not a repository";
			case Ready: "Not synced";
			case Checking: "Checking";
			case Uploading: "Uploading";
			case Verifying: "Verifying";
			case Synced: "Synced";
			case Pending: "Offline";
			case Conflict: "Conflict";
			case Failed: "Failed";
			case Expiring: "Expiring";
			case Expired: "Expired";
			case Deleting: "Deleting";
		};
		var variant:ashui.components.BadgeVariant = switch state.phase {
			case Synced: Success;
			case Failed | Conflict | Expired: Destructive;
			case Pending | Expiring | Checking | Uploading | Verifying | Deleting: Warning;
			case _: Secondary;
		};
		return <badge id="rayde-sync-phase" size={Sm} variant={variant}>${label}</badge>;
	}

	function body(state:SyncState):Element
		return switch state.phase {
			case SignedOut: gate("Sign in to sync", "Cloud Sync keeps a copy of this workspace in your rayde.org account, so you can open it in a browser or on another device. Local editing and Git work without an account.",
				"rayde-sync-sign-in", "Sign In", props.onSignIn, state);
			case NoGit: gate("This folder is not a Git repository", "Cloud Sync works from a Git working tree. Initializing a repository is a separate step and never happens as part of a sync.",
				"rayde-sync-init-git", "Initialize Git", props.onInitGit, state);
			case Ready: ready(state);
			case Checking | Uploading | Verifying: working(state);
			case Failed: failed(state);
			case Expired: expired(state);
			case Deleting: deleting(state);
			case Synced | Pending | Conflict | Expiring: published(state);
		};

	function gate(title:String, reason:String, id:String, action:String, run:Void->Void, state:SyncState):Element
		return <div class="rayde-sync-section">
			<div class="rayde-sync-welcome"><icon document={Icons.UPLOAD_CLOUD_2_FILL} class="size-6"/></div>
			<text class="rayde-sync-hero-title">${title}</text>
			<text id="rayde-sync-reason" class="rayde-sync-muted">${reason}</text>
			<div class="rayde-sync-actions"><button id={id} size={Sm} onClick={_ -> run()}>${action}</button></div>
		</div>;

	/** The preflight: what a sync would send, before anything is. */
	function ready(state:SyncState):Element
		return <div class="rayde-sync-section">
			<div class="rayde-sync-card rayde-sync-section">
				<div class="rayde-sync-details rayde-sync-flush">
					${detail("Branch", state.branch == "" ? "No commits yet" : state.branch, "rayde-sync-branch")}
					${detail("Files", state.files + " files · " + Sync.bytes(state.bytes), "rayde-sync-files")}
					${detail("Left out", state.excluded + " excluded", "rayde-sync-excluded")}
					${detail("Storage", Sync.bytes(state.allocation) + " allocation", "rayde-sync-allocation")}
				</div>
				<div class="rayde-sync-detail"><text>Keep the cloud copy for</text>${expiryChoice(state)}</div>
				<text class="rayde-sync-muted">The clock starts at your first sync, and viewing or retrying never extends it.</text>
			</div>
			<div class="rayde-sync-actions"><button id="rayde-sync-start" size={Sm} onClick={_ -> props.onSync()}><icon document={Icons.UPLOAD_CLOUD_2_FILL} class="size-3.5 shrink-0"/>Sync</button></div>
		</div>;

	function expiryChoice(state:SyncState):Element
		return <select id="rayde-sync-expiry" size={Sm} value={Std.string(state.expiryHours)} onChange={v -> props.onExpiry(Std.parseInt(v) ?? 24)}>
			<select-item value="1">${Sync.hours(1)}</select-item>
			<select-item value="6">${Sync.hours(6)}</select-item>
			<select-item value="24">${Sync.hours(24)}</select-item>
			<select-item value="72">${Sync.hours(72)}</select-item>
		</select>;

	function working(state:SyncState):Element {
		var title = switch state.phase {
			case Checking: "Checking what changed";
			case Verifying: "Verifying the upload";
			case _: "Uploading " + Sync.bytes(state.sent) + " of " + Sync.bytes(state.total);
		};
		return <div class="rayde-sync-section">
			<div class="rayde-sync-card rayde-sync-section">
				<text id="rayde-sync-progress-title" class="rayde-sync-title">${title}</text>
				<if {state.phase == Uploading}><progress id="rayde-sync-progress" size={Sm} value={Sync.progress(state) * 100} max={100}/>
				<else><progress id="rayde-sync-progress" size={Sm}/></if>
				<text class="rayde-sync-muted">The last good copy stays in place until this one is complete.</text>
			</div>
			<div class="rayde-sync-actions"><button id="rayde-sync-cancel" variant={Outline} size={Sm} onClick={_ -> props.onCancel()}>Cancel</button></div>
		</div>;
	}

	function failed(state:SyncState):Element
		return <div class="rayde-sync-section">
			<div class="rayde-sync-card rayde-sync-section">
				<text id="rayde-sync-error" class="rayde-sync-error">${state.message == "" ? "The sync did not finish." : state.message}</text>
				<text class="rayde-sync-muted">Nothing was lost. The last good cloud copy, if there is one, is unchanged.</text>
			</div>
			<div class="rayde-sync-actions"><button id="rayde-sync-retry" size={Sm} onClick={_ -> props.onRetry()}><icon document={Icons.REFRESH_LINE} class="size-3.5 shrink-0"/>Retry</button></div>
		</div>;

	function expired(state:SyncState):Element
		return <div class="rayde-sync-section">
			<div class="rayde-sync-card rayde-sync-section">
				<text id="rayde-sync-expired" class="rayde-sync-title">The cloud copy has expired</text>
				<text class="rayde-sync-muted">Your local files were never touched. Sync again to make a new cloud copy.</text>
			</div>
			<div class="rayde-sync-actions"><button id="rayde-sync-start" size={Sm} onClick={_ -> props.onSync()}>Sync again</button></div>
		</div>;

	function deleting(state:SyncState):Element
		return <div class="rayde-sync-section"><div class="rayde-sync-card rayde-sync-section">
			<text id="rayde-sync-deleting" class="rayde-sync-title">Deleting the cloud copy</text>
			<progress size={Sm}/>
			<text class="rayde-sync-muted">Your local files are not affected.</text>
		</div></div>;

	/** After a first publication: the link, what the copy holds, and what can be done with it. */
	function published(state:SyncState):Element {
		var left = state.expiresAt - props.now();
		return <div class="rayde-sync-section">
			<div class="rayde-sync-card rayde-sync-section">
				<div class="rayde-sync-link">
					<text id="rayde-sync-url" class="rayde-sync-url">${state.url}</text>
				</div>
				<div class="rayde-sync-actions">
					<button id="rayde-sync-copy" size={Sm} onClick={_ -> props.onCopy()}><icon document={Icons.FILE_COPY_LINE} class="size-3.5 shrink-0"/>Copy Link</button>
					<button id="rayde-sync-open" variant={Outline} size={Sm} onClick={_ -> props.onOpen()}><icon document={Icons.EXTERNAL_LINK_LINE} class="size-3.5 shrink-0"/>Open</button>
				</div>
				<div class="rayde-sync-details">
					${detail("Last sync", state.lastSync <= 0 ? "Not yet" : Sync.ago(props.now() - state.lastSync), "rayde-sync-last")}
					${detail("Storage", Sync.bytes(state.used) + " of " + Sync.bytes(state.allocation), "rayde-sync-used")}
					${detail("Expires", state.expiresAt <= 0 ? "—" : Sync.remaining(left) + " left", "rayde-sync-expires")}
					${detail("Cloud compute", compute(state.compute), "rayde-sync-compute")}
				</div>
			</div>
			<if {state.phase == Conflict}><div class="rayde-sync-card rayde-sync-section">
				<text id="rayde-sync-conflict" class="rayde-sync-error">${state.conflicts == 0 ? "The remote copy has changes from another device" : state.conflicts == 1 ? "1 file changed locally and remotely" : state.conflicts + " files changed locally and remotely"}</text>
				<text class="rayde-sync-muted">${state.message == "" ? "Choose local or remote for each." : state.message}</text>
				<div class="rayde-sync-actions">
					<if {state.conflicts == 0}><button id="rayde-sync-pull" size={Sm} onClick={_ -> props.onPull()}><icon document={Icons.REFRESH_LINE} class="size-3.5 shrink-0"/>Pull cloud changes</button></if>
				</div>
				<if {state.conflicts > 0 && state.items != null}>${conflictChoices(state.items, false)}</if>
			</div></if>
			<if {state.phase == Synced && state.message != ""}><text id="rayde-sync-note" class="rayde-sync-muted">${state.message}</text></if>
			<if {state.phase == Pending}><text id="rayde-sync-offline" class="rayde-sync-muted">You are offline. Changes will sync when the connection returns.</text></if>
			<if {state.phase == Expiring}><text id="rayde-sync-expiring" class="rayde-sync-error">The cloud copy expires in ${Sync.remaining(left)}. Extend it to keep it.</text></if>
			<div class="rayde-sync-actions">
				<button id="rayde-sync-now" size={Sm} onClick={_ -> props.onSync()}><icon document={Icons.REFRESH_LINE} class="size-3.5 shrink-0"/>Sync Now</button>
				<button id="rayde-sync-share" variant={Outline} size={Sm} onClick={_ -> props.onShare()}><icon document={Icons.SHARE_LINE} class="size-3.5 shrink-0"/>Share</button>
				<dropdown-menu id="rayde-sync-menu">
					<dropdown-menu-trigger id="rayde-sync-more" variant={Outline} size={Icon}><icon document={Icons.MORE_LINE} class="size-4"/></dropdown-menu-trigger>
					<dropdown-menu-content>
						<dropdown-menu-item id="rayde-sync-pause" onSelect={() -> props.onPause()}>Pause Sync</dropdown-menu-item>
						<dropdown-menu-item id="rayde-sync-export" onSelect={() -> props.onExport()}>Download / Export</dropdown-menu-item>
						<dropdown-menu-item id="rayde-sync-extend" onSelect={() -> props.onExtend()}>Extend Expiry…</dropdown-menu-item>
						<dropdown-menu-separator/>
						<dropdown-menu-item id="rayde-sync-disconnect" onSelect={() -> props.onDisconnect()}>Disconnect This Device</dropdown-menu-item>
						<dropdown-menu-item id="rayde-sync-delete" onSelect={() -> props.onDelete()}>Delete Cloud Copy…</dropdown-menu-item>
					</dropdown-menu-content>
				</dropdown-menu>
			</div>
		</div>;
	}

	/** A browser session that is a copy of a cloud workspace: saving publishes what is here as the next generation, and never over a cloud copy that has moved on. */
	function saveBack(saved:SaveBack):Element
		return <div class="rayde-sync-section">
			<div class="rayde-sync-card rayde-sync-section">
				${detail("Cloud copy", "Generation " + saved.generation, "rayde-sync-generation")}
				<text class="rayde-sync-muted">This workspace is a restored copy of your cloud workspace. Saving publishes what is here as the next generation. If the cloud copy has changed since this one was restored, nothing is overwritten.</text>
				<if {saved.conflicts.length > 0}>${conflictChoices(saved.conflicts, saved.busy)}</if>
				<if {saved.message != "" && saved.failed}><text id="rayde-sync-save-message" class="rayde-sync-error">${saved.message}</text>
				<else><if {saved.message != ""}><text id="rayde-sync-save-message" class="rayde-sync-muted">${saved.message}</text></if></if>
			</div>
			<div class="rayde-sync-actions">
				<if {saved.canMerge && saved.conflicts.length == 0}><button id="rayde-sync-merge" variant={Outline} size={Sm} disabled={saved.busy} onClick={_ -> props.onMerge()}><icon document={Icons.REFRESH_LINE} class="size-3.5 shrink-0"/>Merge cloud changes</button></if>
				<button id="rayde-sync-save" size={Sm} disabled={saved.busy} onClick={_ -> props.onSave()}><icon document={Icons.UPLOAD_CLOUD_2_FILL} class="size-3.5 shrink-0"/>${saved.busy ? "Working…" : "Save to cloud"}</button>
			</div>
		</div>;

	/** The files edited in the same place on both sides: a path that opens the two side by side, and an icon each for keeping the local file or taking the remote one. */
	function conflictChoices(items:Array<ConflictItem>, busy:Bool):Element {
		var undecided = Lambda.count(items, item -> item.choice == "");
		return <div class="flex flex-col gap-1">
			<div class="flex items-center gap-1">
				<text class="rayde-sync-muted flex-1">Local or remote</text>
				<tooltip label="Keep all local" side="top"><button id="rayde-sync-keep-mine" variant={Ghost} size={Icon} disabled={busy} onClick={_ -> props.onResolve("mine")}><icon document={Icons.COMPUTER_LINE} class="size-4"/></button></tooltip>
				<tooltip label="Use all remote" side="top"><button id="rayde-sync-use-cloud" variant={Ghost} size={Icon} disabled={busy} onClick={_ -> props.onResolve("theirs")}><icon document={Icons.CLOUD_LINE} class="size-4"/></button></tooltip>
			</div>
			<for {item in items}>${conflictRow(item, Lambda.indexOf(items, item), busy)}</for>
			<button id="rayde-sync-apply" size={Sm} disabled={busy || undecided > 0} onClick={_ -> props.onApply()}>Apply</button>
		</div>;
	}

	function conflictRow(item:ConflictItem, index:Int, busy:Bool):Element {
		var local:ashui.components.ButtonVariant = item.choice == "mine" ? Primary : Ghost;
		var remote:ashui.components.ButtonVariant = item.choice == "theirs" ? Primary : Ghost;
		return <div class="flex items-center gap-1">
			<tooltip class="flex-1 min-w-0" label={item.reason + " · compare"} side="top"><button id={"rayde-sync-file-" + index} variant={Link} size={Sm} onClick={_ -> props.onDiff(item.path)}><text class="text-xs" wrap={false}>${item.path}</text></button></tooltip>
			<tooltip label="Keep local" side="top"><button id={"rayde-sync-pick-mine-" + index} variant={local} size={Icon} disabled={busy} onClick={_ -> props.onPick(item.path, "mine")}><icon document={Icons.COMPUTER_LINE} class="size-4"/></button></tooltip>
			<tooltip label="Use remote" side="top"><button id={"rayde-sync-pick-theirs-" + index} variant={remote} size={Icon} disabled={busy} onClick={_ -> props.onPick(item.path, "theirs")}><icon document={Icons.CLOUD_LINE} class="size-4"/></button></tooltip>
		</div>;
	}

	function detail(label:String, value:String, id:String):Element
		return <div class="rayde-sync-detail"><text>${label}</text><text id={id} class="rayde-sync-value">${value}</text></div>;

	function compute(value:String):String
		return switch value {
			case "starting": "Starting";
			case "running": "Running";
			case "sleeping": "Sleeping";
			case _: "Not running";
		};
}
