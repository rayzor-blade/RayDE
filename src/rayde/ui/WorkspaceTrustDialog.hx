package rayde.ui;

import ashui.components.Button;
import ashui.components.Dialog;
import ashui.components.Icon;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;

typedef WorkspaceTrustDialogProps = {entry:String, busy:Signal<Bool>, error:Signal<String>, trust:Void->Void, cancel:Void->Void};

/** Project activation waits for an explicit authorship decision. */
class WorkspaceTrustDialog extends Component<WorkspaceTrustDialogProps> {
	final opened = Signal.make(true);

	function render():Element {
		var folder = rayde.settings.WorkspaceTrust.root(props.entry);
		return <dialog id="rayde-workspace-trust" open={opened} onOpenChange={on -> if (!on) props.cancel()}>
			<dialog-content id="rayde-workspace-trust-dialog" size={Md}>
				<dialog-header>
					<div class="flex items-center gap-3"><icon document={Icons.SHIELD_KEYHOLE_LINE} class="size-6 shrink-0 text-warning"/><dialog-title>Trust this project's authors?</dialog-title></div>
					<dialog-description>Projects can run code through build scripts, macros, language servers and extensions. Only open this project if you trust its authors.</dialog-description>
				</dialog-header>
				<div class="flex flex-col gap-1 min-w-0 rounded-md border border-border p-3 bg-background">
					<text class="text-sm font-semibold">${haxe.io.Path.withoutDirectory(folder)}</text>
					<text id="rayde-workspace-trust-path" class="text-xs text-text-secondary">${folder}</text>
				</div>
				<text class="text-xs text-text-secondary">Your choice is remembered for this workspace on this device.</text>
				<if {props.error.get() != ""}><text id="rayde-workspace-trust-error" class="text-sm text-error">${props.error.get()}</text></if>
				<dialog-footer>
					<button id="rayde-workspace-trust-cancel" variant={Outline} onClick={_ -> props.cancel()}>Cancel</button>
					<button id="rayde-workspace-trust-accept" disabled={props.busy.get()} onClick={_ -> { try props.trust() catch (failure:Dynamic) props.error.set(Std.string(failure)); }}>${props.busy.get() ? "Opening…" : "Trust and Open"}</button>
				</dialog-footer>
			</dialog-content>
		</dialog>;
	}
}
