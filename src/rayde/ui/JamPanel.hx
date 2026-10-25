package rayde.ui;

import ashui.components.Button;
import ashui.components.Badge;
import ashui.components.Avatar;
import ashui.components.Avatar.AvatarFallback;
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
	function render():Element
		return <div id="rayde-jam-panel" class="flex flex-col flex-1 min-w-0 min-h-0">
		<div class="rayde-jam-heading">
			<icon document={Icons.JAM_JOYSTICK} class="size-4 shrink-0"/><text class="flex-1">Jam</text><badge variant={Secondary} size={Sm}>Local</badge>
		</div>
		<div class="rayde-jam-scroll">
			<text id="rayde-jam-workspace" class="rayde-jam-workspace">${props.workspace}</text>
			<for {current in [props.session.get()]}>${body(current)}</for>
		</div>
	</div>;

	function body(current:Null<JamSession>):Element {
		if (current == null) {
			var unavailable = Computed.make(() -> !props.canShare());
			return <div class="rayde-jam-section">
			<div class="rayde-jam-welcome"><icon document={Icons.JAM_JOYSTICK} class="size-6"/></div>
			<text class="rayde-jam-hero-title">Code together</text>
			<text class="rayde-jam-muted">Share a document or join someone else's Jam.</text>
			<div id="rayde-jam-selected" class="rayde-jam-file rayde-jam-card flex items-center gap-2 min-w-0">
				<for {file in [props.active.get()]}>
					<if {props.canShare()}><icon document={FileIcons.of(file)} class="size-4 shrink-0"/><text class="flex-1 min-w-0">${haxe.io.Path.withoutDirectory(file)}</text>
					<else><text>Open a text document to get started.</text></if>
				</for>
			</div>
			<div class="rayde-jam-actions">
				<button id="rayde-jam-start" size={Sm} disabled={unavailable} onClick={_ -> props.onStart()}>Start Jam…</button>
				<button id="rayde-jam-join" variant={Outline} size={Sm} disabled={unavailable} onClick={_ -> props.onJoin()}>Join Jam…</button>
			</div>
			<text class="rayde-jam-muted">Continue a saved Jam for this document.</text>
			<div class="rayde-jam-actions">
				<button id="rayde-jam-resume" variant={Outline} size={Sm} disabled={unavailable} onClick={_ -> props.onResume()}>Resume…</button>
				<button id="rayde-jam-rejoin" variant={Outline} size={Sm} disabled={unavailable} onClick={_ -> props.onRejoin()}>Rejoin…</button>
			</div>
		</div>;
		}
		var failure = current.failure, following = current.following;
		var failed = Computed.make(() -> failure.get() != "");
		var summary = <div id="rayde-jam-connection" class="rayde-jam-connection">
			<for {state in [current.status.get()]}>
				<badge size={Sm} variant={state == "connected" ? Success : state == "paused" || state == "failed" ? Destructive : Warning}>
					<icon document={Icons.CIRCLE_FILL} class="size-1.5 shrink-0"/><text>${status(state)}</text>
				</badge>
			</for>
			<badge size={Sm} variant={Secondary} appearance={Outline}>${current.host ? "Host" : "Guest"}</badge>
		</div>;
		ashui.css.Identity.of(summary.tree, summary.node.id)
			.bindBooleanAttribute("data-connected", Computed.make(() -> current.status.get() == "connected" && failure.get() == ""));
		return <div class="rayde-jam-section">
			<div class="rayde-jam-card rayde-jam-section">
				{summary}
				<button id="rayde-jam-open-document" variant={Ghost} class="rayde-jam-document" onClick={_ -> props.onOpenFile()}><icon document={FileIcons.of(current.file)} class="size-4 shrink-0"/><text>${haxe.io.Path.withoutDirectory(current.file)}</text></button>
				<div class="rayde-jam-details">
					<div class="rayde-jam-detail"><text>Sync</text>
						<for {state in [current.status.get() != "connected" ? "Waiting" : current.synced.get() ? "Up to date" : "Sending edits"]}>
							<if {state == "Up to date"}><text id="rayde-jam-sync" class="text-success">${state}</text>
							<else><text id="rayde-jam-sync" class="text-warning">${state}</text></if>
						</for>
					</div>
					<div class="rayde-jam-detail"><text>Recovery</text>
						<for {saved in [current.recoveryStatus.get() == "saved locally"]}>
							<if {saved}><text id="rayde-jam-recovery" class="text-success">Saved locally</text>
							<else><text id="rayde-jam-recovery" class="text-warning">Saving locally</text></if>
						</for>
					</div>
					<div class="rayde-jam-detail"><text>Local file</text>
						<for {dirty in [props.dirty.get().indexOf(current.file)>=0]}>
							<if {dirty}><text id="rayde-jam-save" class="text-warning">Unsaved</text>
							<else><text id="rayde-jam-save" class="text-success">Saved</text></if>
						</for>
					</div>
				</div>
			</div>
			<if {failure.get()!=""}><div class="rayde-jam-card rayde-jam-section"><text id="rayde-jam-error" class="rayde-jam-error">${failure.get()}</text><text class="rayde-jam-muted">Leave this session, then Resume or Rejoin to continue from recovery.</text></div></if>
			<div class="rayde-jam-actions">
				<if {current.host}><button id="rayde-jam-copy" size={Sm} disabled={Computed.make(() -> current.invite.get()=="" || failed.get())} onClick={_ -> props.onCopy()}><icon document={Icons.LINK_M} class="size-3.5 shrink-0"/>Copy Invitation</button></if>
				<tooltip label="Reconnect to this Jam" side="bottom"><button id="rayde-jam-reconnect" variant={Outline} size={Icon} disabled={failed} onClick={_ -> current.pause(false)}><icon document={Icons.REFRESH_LINE} class="size-3.5"/></button></tooltip>
			</div>
			<div class="rayde-jam-section rayde-jam-participants">
				<div class="rayde-jam-section-heading"><text class="rayde-jam-title">Participants</text><badge size={Sm} variant={Secondary}>${Std.string(current.people.get().length)}</badge></div>
				<for {person in current.people.get()}>${participant(current,person)}</for>
				<if {current.people.get().length==0}><text class="rayde-jam-muted">Waiting for a connection.</text></if>
				<if {following.get()!=""}><button id="rayde-jam-stop-follow" variant={Secondary} size={Sm} class="rayde-jam-pill" onClick={_ -> current.stopFollowing()}>Stop Following</button></if>
				<text class="rayde-jam-muted">Follow a participant's caret and view. Navigating or typing in your editor stops following.</text>
			</div>
			<div class="rayde-jam-section rayde-jam-footer">
				<tooltip label="Save shared edit history for local recovery. This does not save the source file." side="top"><button id="rayde-jam-checkpoint" variant={Ghost} size={Sm} disabled={Computed.make(() -> failed.get() || !current.initialized.get())} onClick={_ -> current.checkpoint()}><icon document={Icons.SAVE_3_LINE} class="size-3.5 shrink-0"/>Save recovery checkpoint</button></tooltip>
				<button id="rayde-jam-leave" variant={Outline} size={Sm} class="rayde-jam-leave" onClick={_ -> props.onLeave()}><icon document={Icons.LOGOUT_BOX_LINE} class="size-3.5 shrink-0"/>${current.host ? "End Jam" : "Leave Jam"}</button>
			</div>
		</div>;
	}

	function participant(current:JamSession, person:{id:String, name:String}):Element {
		var color = 0;
		for (i in 0...person.id.length)
			color = (color + person.id.charCodeAt(i)) % 4;
		var letters = new haxe.iterators.StringIteratorUnicode(StringTools.trim(person.name));
		var initial = letters.hasNext() ? String.fromCharCode(letters.next()).toUpperCase() : "?";
		var avatar = <avatar size="sm" class="rayde-jam-avatar"><avatar-fallback><text>${initial}</text></avatar-fallback></avatar>;
		ashui.css.Identity.of(avatar.tree, avatar.node.id).setAttribute("data-color", Std.string(color));
		return <div class="rayde-jam-person">
			{avatar}
			<tooltip label={person.name} side="top"><text class="rayde-jam-person-name">${person.name}</text></tooltip>
			<if {current.isSelf(person.id)}><badge variant={Secondary} size={Sm}>You</badge>
			<else><button id={"rayde-jam-follow-"+person.id} variant={Outline} size={Sm} class="rayde-jam-pill" disabled={Computed.make(() -> current.positionOf(person.id)==null || current.status.get()!="connected")} onClick={_ -> props.onFollow(person.id)}>${current.following.get()==person.id ? "Following" : "Follow"}</button></if>
		</div>;
	}

	static function status(value:String):String
		return switch value {
			case "connected": "Connected";
			case "connecting": "Connecting…";
			case "reconnecting": "Reconnecting…";
			case "paused": "Disconnected";
			case "failed": "Connection ended";
			case _: "Disconnected";
		};
}
