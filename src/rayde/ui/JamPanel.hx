package rayde.ui;

import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Computed;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.jam.JamSession;

typedef JamPanelProps = {
	workspace:String,
	session:Signal<Null<JamSession>>,
	active:Signal<String>,
	dirty:Signal<Array<String>>,
	canShare:Void->Bool,
	onClose:Void->Void,
	onStart:Void->Void,
	onJoin:Void->Void,
	onResume:Void->Void,
	onRejoin:Void->Void,
	onOpenFile:Void->Void,
	onCopy:Void->Void,
	onLeave:Void->Void,
	onFollow:String->Void
};

/** This view can close independently of the workspace's live session. */
class JamPanel extends Component<JamPanelProps> {
	function render():Element return <div id="rayde-jam-panel" class="flex flex-col flex-1 min-w-0 min-h-0">
		<div class="rayde-jam-heading">
			<icon document={Icons.JAM_JOYSTICK} class="size-4 shrink-0"/><text class="flex-1">Jam</text>
			<tooltip label="Hide Jam" side="bottom"><button id="rayde-jam-hide" variant={Ghost} size={Icon} onClick={_ -> props.onClose()}><icon document={Icons.CLOSE_LINE} class="size-4"/></button></tooltip>
		</div>
		<div class="rayde-jam-scroll">
			<text id="rayde-jam-workspace" class="rayde-jam-muted">${props.workspace}</text>
			<for {current in [props.session.get()]}>${body(current)}</for>
		</div>
	</div>;

	function body(current:Null<JamSession>):Element {
		if (current == null) return <div class="rayde-jam-section">
			<text class="rayde-jam-title">Code together</text>
			<text class="rayde-jam-muted">Share a document or join someone else's Jam.</text>
			<text id="rayde-jam-selected" class="rayde-jam-file">${props.canShare() ? haxe.io.Path.withoutDirectory(props.active.get()) : "Open a text document to get started."}</text>
			<div class="rayde-jam-actions">
				<button id="rayde-jam-start" size={Sm} disabled={!props.canShare()} onClick={_ -> props.onStart()}>Start Jam…</button>
				<button id="rayde-jam-join" variant={Outline} size={Sm} disabled={!props.canShare()} onClick={_ -> props.onJoin()}>Join Jam…</button>
			</div>
			<text class="rayde-jam-muted">Continue a saved Jam for this document.</text>
			<div class="rayde-jam-actions">
				<button id="rayde-jam-resume" variant={Outline} size={Sm} disabled={!props.canShare()} onClick={_ -> props.onResume()}>Resume…</button>
				<button id="rayde-jam-rejoin" variant={Outline} size={Sm} disabled={!props.canShare()} onClick={_ -> props.onRejoin()}>Rejoin…</button>
			</div>
		</div>;
		var failure=current.failure, following=current.following;
		var summary=<div id="rayde-jam-connection" class="rayde-jam-connection"><icon document={Icons.CIRCLE_FILL} class="size-2 shrink-0"/><text>${status(current.status.get())}</text></div>;
		ashui.css.Identity.of(summary.tree,summary.node.id).bindBooleanAttribute("data-connected",Computed.make(() -> current.status.get()=="connected" && failure.get()==""));
		return <div class="rayde-jam-section">
			{summary}
			<button id="rayde-jam-open-document" variant={Ghost} class="rayde-jam-document" onClick={_ -> props.onOpenFile()}><icon document={Icons.FILE_CODE_LINE} class="size-4 shrink-0"/><text>${haxe.io.Path.withoutDirectory(current.file)}</text></button>
			<div class="rayde-jam-details">
				<text>${current.host ? "Hosting this Jam" : "Joined this Jam"}</text>
				<text id="rayde-jam-sync">${current.status.get() != "connected" ? "Sync · waiting for connection" : current.synced.get() ? "Sync · up to date" : "Sync · sending edits"}</text>
				<text id="rayde-jam-recovery">${"Recovery · " + current.recoveryStatus.get()}</text>
				<text id="rayde-jam-save">${props.dirty.get().indexOf(current.file)>=0 ? "Local file · unsaved changes" : "Local file · saved"}</text>
			</div>
			<if {failure.get()!=""}><text id="rayde-jam-error" class="rayde-jam-error">${failure.get()}</text><text class="rayde-jam-muted">Leave this session, then Resume or Rejoin to continue from recovery.</text></if>
			<div class="rayde-jam-actions">
				<if {current.host}><button id="rayde-jam-copy" variant={Outline} size={Sm} disabled={current.invite.get()=="" || failure.get()!=""} onClick={_ -> props.onCopy()}><icon document={Icons.LINK_M} class="size-3.5"/>Copy Invitation</button></if>
				<button id="rayde-jam-reconnect" variant={Outline} size={Sm} disabled={failure.get()!=""} onClick={_ -> current.pause(false)}>Reconnect</button>
			</div>
			<button id="rayde-jam-checkpoint" variant={Outline} size={Sm} disabled={failure.get()!="" || !current.initialized.get()} onClick={_ -> current.checkpoint()}>Save Recovery Checkpoint</button>
			<div class="rayde-jam-section rayde-jam-participants">
				<text class="rayde-jam-title">${"Participants · " + current.people.get().length}</text>
				<for {person in current.people.get()}>${participant(current,person)}</for>
				<if {current.people.get().length==0}><text class="rayde-jam-muted">Waiting for a connection.</text></if>
				<if {following.get()!=""}><button id="rayde-jam-stop-follow" variant={Secondary} size={Sm} onClick={_ -> current.stopFollowing()}>Stop Following</button></if>
				<text class="rayde-jam-muted">Follow a participant's caret and view. Navigating or typing in your editor stops following.</text>
			</div>
			<button id="rayde-jam-leave" variant={Destructive} size={Sm} onClick={_ -> props.onLeave()}>${current.host ? "End Jam" : "Leave Jam"}</button>
		</div>;
	}
	function participant(current:JamSession,person:{id:String,name:String}):Element return <div class="rayde-jam-person">
		<icon document={Icons.USER_LINE} class="size-4 shrink-0"/>
		<tooltip label={person.name} side="top"><text class="rayde-jam-person-name">${person.name}</text></tooltip>
		<if {current.isSelf(person.id)}><text class="rayde-jam-muted">You</text>
		<else><button id={"rayde-jam-follow-"+person.id} variant={Ghost} size={Sm} disabled={Computed.make(() -> current.positionOf(person.id)==null || current.status.get()!="connected")} onClick={_ -> props.onFollow(person.id)}>${current.following.get()==person.id ? "Following" : "Follow"}</button></if>
	</div>;

	static function status(value:String):String return switch value {
		case "connected": "Connected";
		case "connecting": "Connecting…";
		case "reconnecting": "Reconnecting…";
		case "paused": "Disconnected";
		case "failed": "Connection ended";
		case _: "Disconnected";
	};
}
