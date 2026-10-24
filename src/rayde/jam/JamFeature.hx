package rayde.jam;

import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Computed;
import ashui.reactive.Signal;
import rayde.ui.Contributions;
import rayde.ui.Host;
import rayde.ui.Icons;
import rayde.ui.JamPanel;

/**
	Local Jam collaboration as a feature: it registers its commands, its activity icon, its status item and its side panel,
	and listens for the editors, files and tabs it needs to follow. The workbench knows none of it.
**/
class JamFeature {
	final host:Host;
	static final installed = new haxe.ds.ObjectMap<Contributions, JamFeature>();
	public final session = Signal.make((null : Null<JamSession>));
	var poller:Null<ashui.animation.AnimationScheduler.Timer>;

	/** Installs the feature in the workbench `host` stands for. */
	public static function install(host:Host):Void
		installed.set(host.contributions, new JamFeature(host));

	/** The Jam feature of a workbench, for tests and tools that look at it. */
	public static function of(contributions:Contributions):Null<JamFeature>
		return installed.get(contributions);

	/** Whether the feature is waiting on a timer for the room. */
	public function polling():Bool
		return poller != null;

	function new(host:Host) {
		this.host = host;
		var c = host.contributions;
		c.command({id:"jam.open", label:"Jam: Open Panel", icon:Icons.JAM_JOYSTICK, run:showJam});
		c.command({id:"jam.stopFollowing", label:"Jam: Stop Following", icon:Icons.USER_LINE, run:stopFollowing});
		c.command({id:"jam.start", label:"Jam: Share Active Document…", icon:Icons.TEAM_LINE, run:askStartJam});
		c.command({id:"jam.join", label:"Jam: Join Shared Document…", icon:Icons.TEAM_LINE, run:askJoinJam});
		c.command({id:"jam.resume", label:"Jam: Resume Saved Document…", icon:Icons.TEAM_LINE, run:() -> askRestoreJam(true)});
		c.command({id:"jam.rejoin", label:"Jam: Rejoin Saved Document…", icon:Icons.TEAM_LINE, run:() -> askRestoreJam(false)});
		c.command({id:"jam.copy", label:"Jam: Copy Invitation", icon:Icons.LINK_M, run:copyJamInvite});
		c.command({id:"jam.leave", label:"Jam: Leave", icon:Icons.LOGOUT_BOX_LINE, run:leaveJam});
		c.activity({id:"rayde-activity-jam", title:"Jam", icon:Icons.JAM_JOYSTICK, order:50, on:() -> host.sidebarShown("jam"),
			run:() -> if (host.sidebarShown("jam")) host.hideSidebar() else showJam()});
		c.status({id:"jam", place:"left", order:100, build:() -> <for {current in [session.get()]}>${status(current)}</for>});
		c.sidebar("jam", panel);
		c.onEditor((file, editor) -> new JamEditor(editor, file, () -> session.get()));
		c.onNavigate(stopFollowing);
		c.onActive(file -> { var current = session.get(); if (current != null && file != current.file) current.stopFollowing(); });
		c.onEdited(file -> { var current = session.get(); if (current != null && current.file == file) current.acceptBuffer(); });
		c.onFrame(pollJam);
		c.retains(() -> session.get() == null ? [] : [session.get().file]);
		c.refuses((path, doing) -> session.get() != null && rayde.files.FileOps.inside(path, session.get().file) ? "Leave the Jam before " + doing + " its shared document" : null);
		c.readOnlyWhen(file -> { var current = session.get(); return current != null && current.file == file && !current.editable(); });
		c.onClose(() -> { leaveJam(); installed.remove(c); });
	}

	function panel():Element
		return <jam-panel workspace={host.name} session={session} active={host.active} dirty={host.dirty} canShare={canShareJam}
			onClose={host.hideSidebar} onStart={askStartJam} onJoin={askJoinJam} onResume={() -> askRestoreJam(true)} onRejoin={() -> askRestoreJam(false)}
			onOpenFile={() -> { if (session.get() != null) host.open(session.get().file); }} onCopy={copyJamInvite} onLeave={leaveJam} onFollow={followJam}/>;

	function stopFollowing():Void {
		var current = session.get();
		if (current != null) current.stopFollowing();
	}

	function canShareJam():Bool
		return host.isDocument(host.active.get());

	public function showJam():Void
		host.showSidebar("jam");
	public function followJam(id:String):Void {
		var current=session.get();
		if (current == null) return;
		host.open(current.file);
		if (!current.follow(id)) host.say("Wait for this participant's position before following");
	}

	function jamFile():String {
		var file=host.active.get();
		if (session.get() != null) throw "Leave the current Jam before starting another";
		if (!host.isDocument(file))
			throw "Open a text document in this workspace first";
		return file;
	}

	function askStartJam():Void {
		try {
			var file=jamFile();
			host.ask({title:"Share " + haxe.io.Path.withoutDirectory(file),description:"Share this document in a local Jam. Participants can edit it. Save writes changes to your local copy. Closing the host window ends the room. Starting a fresh Jam replaces this file's previous Jam checkpoint; use Resume Saved Document to recover it.",action:"Start Jam",hasInput:true,value:Sys.getEnv("USER") ?? "Host",placeholder:"Your display name",
				check:name -> StringTools.trim(name) == "" || haxe.io.Bytes.ofString(name).length > 64 ? "Enter a name of 1–64 bytes" : null,
				accept:name -> begin(file,true,name,"")});
		} catch (error:Dynamic) host.say(Std.string(error));
	}

	function askJoinJam():Void {
		try {
			var file=jamFile();
			if (host.dirty.get().indexOf(file) >= 0) throw "Save or discard this document's changes before joining";
			host.ask({title:"Join a local Jam",description:"Open the matching file in your own workspace copy. Joining replaces its editor buffer with the shared document. Your disk copy changes only when you save. Joining fresh replaces its previous Jam checkpoint; use Rejoin Saved Document to retain offline edits.",action:"Join Jam",hasInput:true,placeholder:"ws://127.0.0.1:port/jam/invitation",accept:invitation -> begin(file,false,Sys.getEnv("USER") ?? "Guest",StringTools.trim(invitation))});
		} catch (error:Dynamic) host.say(Std.string(error));
	}

	function jamRecovery(file:String):String return host.cwd + "/.rayde/jam/" + haxe.crypto.Sha256.encode(file);

	function askRestoreJam(hosting:Bool):Void {
		try {
			var file=jamFile();
			if (host.dirty.get().indexOf(file) >= 0) throw "Save or discard this document's changes before restoring a Jam";
			host.ask({title:hosting ? "Resume saved Jam" : "Rejoin saved Jam",description:hosting ? "Restore this file's saved shared document into the editor and create a new invitation. Participants can rejoin using that invitation. Your disk copy changes only when you save." : "Restore this file's saved shared document and merge its offline edits into the original Jam. Ask the host for the current invitation. Your disk copy changes only when you save.",action:hosting ? "Resume Jam" : "Rejoin Jam",hasInput:!hosting,placeholder:"ws://127.0.0.1:port/jam/invitation",accept:invitation -> begin(file,hosting,Sys.getEnv("USER") ?? "Peer",hosting ? "" : StringTools.trim(invitation),true)});
		} catch (error:Dynamic) host.say(Std.string(error));
	}

	/** Starts or joins a room on `file`; the prompts of the commands call it, and so do tests. */
	public function begin(file:String,hosting:Bool,name:String,invitation:String,restore:Bool=false):Void {
		if (session.get() != null || !host.hasBuffer(file)) throw "Open the document and leave any existing Jam first";
		if ((!hosting || restore) && host.dirty.get().indexOf(file) >= 0) throw "Save or discard this document's changes before joining";
		var current=new JamSession(file,host.state(file),hosting,name,invitation,() -> { if (!host.closed()) host.edited(file); },jamRecovery(file),restore);
		session.set(current);
		var editor=host.editorOf(file);
		if (editor != null) current.moved(editor.editing.caret.get(),editor.editing.anchor.get());
		pollJam(); scheduleJam(); showJam();
	}

	function pollJam():Void {
		var current=session.get();
		if (current == null || !current.pending()) return;
		var editor=host.editorOf(current.file);
		if (editor != null && editor.editing.composing.get() != "") return;
		if (editor != null) current.remember(editor.editing.caret.get(),editor.editing.anchor.get());
		current.poll();
	}

	function scheduleJam():Void {
		var current=session.get();
		if (host.closed() || current == null || current.canWake() || current.failure.get() != "") return;
		poller=ashui.animation.AnimationScheduler.main.after(.05,() -> { poller=null; pollJam(); scheduleJam(); });
	}

	function copyJamInvite():Void {
		var current=session.get();
		if (current == null || current.invite.get() == "") { host.say("No local Jam invitation is available"); return; }
		ashui.input.Clipboard.setText(current.invite.get()); host.say("Jam invitation copied");
	}

	function leaveJam():Void {
		if (poller != null) poller.cancel(); poller=null;
		var current=session.get();
		if (current != null) current.dispose();
		session.set(null);
		if (!host.closed()) host.releaseDocuments();
	}

	function status(current:Null<JamSession>):Element {
		var label=Computed.make(() -> {
			if (current == null) return "";
			var person=Lambda.find(current.people.get(),p -> p.id == current.following.get());
			return "Jam · " + (person == null ? current.status.get() : "following " + person.name) + (current.people.get().length > 0 ? " · " + current.people.get().length : "");
		});
		var live=Computed.make(() -> current != null && current.status.get() == "connected" && current.failure.get() == "");
		var symbol:Element = <icon document={Icons.JAM_JOYSTICK} class="size-4 rayde-jam-icon"/>;
		var identity=ashui.css.Identity.of(symbol.tree,symbol.node.id);
		identity.bindBooleanAttribute("data-live",live);
		identity.setAttribute("data-idle",current == null ? "" : null);
		var picture:Element = <div class="relative size-4 shrink-0"><if {live}><icon document={Icons.JAM_JOYSTICK} class="absolute inset-0 size-4 rayde-jam-shadow"/></if>{symbol}</div>;
		var description=Computed.make(() -> current == null ? "Open Jam" : current.failure.get() != "" ? current.failure.get() : haxe.io.Path.withoutDirectory(current.file) + " — " + current.recoveryStatus.get() + " — " + current.people.get().map(p -> p.name).join(", "));
		return <tooltip label={description} side="top"><button id="rayde-jam-status" variant={Ghost} class="rayde-status-item" onClick={_ -> showJam()}>{picture}<text class="rayde-jam-status-label">${label}</text></button></tooltip>;
	}
}
