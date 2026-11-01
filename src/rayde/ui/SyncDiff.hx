package rayde.ui;

import ashui.components.Button;
import ashui.components.CodeDiff;
import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Computed;
import ashui.reactive.Signal;
import ashui.ui.Component;

typedef SyncDiffProps = {
	file:String,
	/** What the cloud copy holds, which does not change while the tab is open. */
	remote:String,
	/** The local file's live text, so edits show as they are made. */
	buffer:Signal<String>,
	onOpen:Void->Void
};

/** A file of the cloud copy against the local one, in the editor's own diff view: remote on the left or above, local as it is now. */
class SyncDiff extends Component<SyncDiffProps> {
	function render():Element {
		var layout = Signal.make("inline");
		return <div id="rayde-sync-diff" class="flex flex-col flex-1 min-h-0 min-w-0">
			<div class="flex items-center gap-2 px-3 py-2 border-b shrink-0">
				<icon document={Icons.CLOUD_LINE} class="size-4 shrink-0 text-text-secondary"/>
				<text class="text-xs text-text-secondary shrink-0">Remote</text>
				<text class="text-xs text-text-tertiary shrink-0">→</text>
				<icon document={Icons.COMPUTER_LINE} class="size-4 shrink-0 text-text-secondary"/>
				<text class="text-xs text-text-secondary flex-1 min-w-0">Local</text>
				<tooltip label={Computed.make(() -> layout.get() == "inline" ? "Side by side" : "Inline diff")} side="bottom"><button id="rayde-sync-diff-layout" variant={Ghost} size={Icon} onClick={_ -> layout.set(layout.get() == "inline" ? "split" : "inline")}><icon document={Icons.LAYOUT_COLUMN_LINE} class="size-4"/></button></tooltip>
				<tooltip label="Open the local file" side="bottom"><button id="rayde-sync-diff-open" variant={Ghost} size={Icon} onClick={_ -> props.onOpen()}><icon document={Icons.FILE_CODE_LINE} class="size-4"/></button></tooltip>
			</div>
			<code-diff original={props.remote} modified={props.buffer} language={rayde.ui.workbench.EditorPart.languageOf(props.file)} layout={layout} class="flex-1 min-h-0"/>
		</div>;
	}
}
