package rayde.ext;

import ashui.animation.AnimationScheduler;
import ashui.input.Interaction;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.ui.TopLayer;
import ashui.types.Style.Overflow;

/** A modeless commit card stays usable while the pointer moves into its scrollable message. */
class CommitPopover {
	final tree:LayoutTree;
	final scope:Owner;
	final network:Bool;
	var entry:TopEntry;
	var owner:Owner;
	var leaving:ashui.animation.AnimationScheduler.Timer;
	var over = false;
	public var id(default, null) = "";

	public function new(tree:LayoutTree, scope:Owner, network:Bool) {
		this.tree = tree; this.scope = scope; this.network = network;
		scope.run(() -> Owner.onCleanup(hide));
	}

	public function show(data:Dynamic, anchor:{x:Float, y:Float, width:Float, height:Float}):Void {
		if (data == null || data.id == id || anchor == null || tree.root == null) return;
		hide(); id = data.id;
		scope.run(() -> owner = new Owner(tree));
		var current = owner;
		var panel = current.run(() -> {
			var profile = Signal.make(data);
			var date = Date.fromTime((data.time:Float) * 1000).toString();
			var message:String = data.message == null ? data.subject : data.message;
			return <div class="rayde-git-popover">
				<div class="rayde-git-person">
					${new GitAvatar({profile:profile, network:network})}
					<div class="rayde-git-identity"><text class="rayde-git-name">{data.author}</text></div>
				</div>
				<div class="rayde-git-hash"><text class="rayde-git-muted">{data.id}</text>
					${new ashui.components.Tooltip({label:"Copy commit hash"}, [new ashui.components.Button({id:"git-commit-copy", variant:Ghost, size:Icon, onClick:_ -> ashui.input.Clipboard.setText(data.id)}, [new ashui.components.Icon({document:rayde.ui.Icons.FILE_COPY_LINE})])])}
				</div>
				<text class="rayde-git-muted">{date}</text>
				<div class="rayde-git-message" overflow={Overflow.Scroll}><text>{message}</text></div>
			</div>;
		});
		var input = Interaction.of(panel.node);
		input.onPointerEnter(_ -> { over = true; cancelLeave(); });
		input.onPointerLeave(_ -> { over = false; leave(); });
		entry = TopLayer.open(tree, panel, Beside(anchor.x, anchor.y, anchor.width, anchor.height, "bottom", 4, "start"), null, () -> {
			current.dispose(); if (owner == current) { owner = null; entry = null; id = ""; }
		}, false, true, true);
	}

	public function leave():Void {
		cancelLeave();
		leaving = AnimationScheduler.main.after(.18, () -> { leaving = null; if (!over) hide(); });
	}
	public function stay():Void cancelLeave();
	function cancelLeave():Void { if (leaving != null) leaving.cancel(); leaving = null; }
	public function hide():Void {
		cancelLeave();
		var opened = entry; entry = null; id = ""; over = false;
		if (opened != null) opened.close();
		if (owner != null) { owner.dispose(); owner = null; }
	}
}
