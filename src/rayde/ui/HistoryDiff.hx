package rayde.ui;

import ashui.components.Button;
import ashui.components.CodeDiff;
import ashui.components.Icon;
import ashui.components.Select;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Computed;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.reactive.Watch;
import ashui.ui.Component;
import rayde.history.FileComparison;
import rayde.history.LineOwners.HistoryJournal;
import rayde.ui.Contributions.ComparisonSource;

typedef HistoryDiffProps = {
	comparison:FileComparison,
	buffer:Signal<String>,
	journal:Void->HistoryJournal,
	source:Void->Null<ComparisonSource>,
	onOpen:Void->Void
};

/** A fixed revision against the live unsaved buffer, independent of which editor pane is typing. */
class HistoryDiff extends Component<HistoryDiffProps> {
	function render():Element {
		var model = props.comparison;
		model.mount();
		Owner.onCleanup(model.suspend);
		new Watch(() -> {
			return {text: props.buffer.get(), source: props.source()};
		}, value -> model.update(value.text, props.journal(), value.source),
			(_, _) -> false);
		return <div id="rayde-history-diff" class="flex flex-col flex-1 min-h-0 min-w-0">
			<div class="flex items-center gap-2 px-3 py-2 border-b shrink-0">
				<icon document={Icons.FILE_HISTORY_LINE} class="size-4 shrink-0 text-text-secondary"/>
				<select id="rayde-history-diff-source" value={model.selected} size={Sm} class="flex-1 min-w-0" onChange={model.choose}>
					<for {choice in model.choices}><select-item value={choice.id}>${choice.label}</select-item></for>
				</select>
				<text class="text-xs text-text-tertiary shrink-0">→ Live</text>
				<tooltip label="Refresh history sources" side="bottom"><button id="rayde-history-diff-refresh" variant={Ghost} size={Icon} onClick={_ -> { model.update(props.buffer.get(),props.journal(),props.source()); model.refresh(); }}><icon document={Icons.REFRESH_LINE} class="size-4"/></button></tooltip>
				<tooltip label={Computed.make(() -> model.layout.get() == "inline" ? "Side by side" : "Inline diff")} side="bottom"><button id="rayde-history-diff-layout" variant={Ghost} size={Icon} onClick={_ -> model.layout.set(model.layout.get() == "inline" ? "split" : "inline")}><if {model.layout.get() == "inline"}><icon document={Icons.LAYOUT_COLUMN_LINE} class="size-4"/><else><icon document={Icons.LAYOUT_ROW_LINE} class="size-4"/></if></button></tooltip>
				<tooltip label="Open file" side="bottom"><button id="rayde-history-diff-open" variant={Ghost} size={Icon} onClick={_ -> props.onOpen()}><icon document={Icons.FILE_CODE_LINE} class="size-4"/></button></tooltip>
			</div>
			<if {model.loading.get()}><text class="text-xs text-text-secondary px-3 py-1 shrink-0">Updating history diff…</text></if>
			<if {model.error.get() != ""}><tooltip label={model.error}><text class="text-xs text-error px-3 py-2 shrink-0">Could not load this revision. Refresh or select another revision.</text></tooltip></if>
			<if {model.note.get() != ""}><text class="text-xs text-text-tertiary px-3 py-1 shrink-0">${model.note.get()}</text></if>
			<code-diff original={model.original} modified={model.modified} language={rayde.ui.workbench.EditorPart.languageOf(model.file)} layout={model.layout} hunks={model.hunks} lineHints={model.hints} navigation={true} class="flex-1 min-h-0"/>
		</div>;
	}
}
