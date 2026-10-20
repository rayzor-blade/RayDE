package rayde.ui;

import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.history.LocalHistory;

typedef LocalTimelineProps = {
	history:LocalHistory, revision:Signal<Int>, file:Void->Null<String>, text:String->String,
	onPreview:(String, Int)->Void
};

/** Only revision labels are mounted; file contents are reconstructed when a revision is opened. */
class LocalTimeline extends Component<LocalTimelineProps> {
	function render():Element {
		var count = Signal.make(20);
		return <div id="rayde-local-timeline" class="flex flex-col min-h-0 shrink-0">
			<div class="px-3 py-1"><text class="text-xs text-text-secondary">Local history</text></div>
			<div class="flex flex-col min-h-0 overflow-auto" maxHeight={104}>
				<for {key in [{file:props.file(), revision:props.revision.get(), count:count.get()}]}>${entries(key.file, key.count, count)}</for>
			</div>
		</div>;
	}

	function entries(file:Null<String>, count:Int, shown:Signal<Int>):Element {
		if (file == null) return <div class="px-3 py-1"><text class="text-xs text-text-secondary">Open a file to view local history</text></div>;
		var entries = props.history.entries(file, props.text(file));
		return <div class="flex flex-col min-w-0">{[for (entry in entries.slice(0, count))
			<tooltip label={entry.kind + " · " + Date.fromTime(entry.time).toString()} side="right">
				<button id={"rayde-local-revision-" + entry.id} variant={Ghost} class="rayde-local-revision justify-start min-w-0" onClick={_ -> props.onPreview(file, entry.id)}>
					<div class="flex items-center gap-2 min-w-0 flex-1"><icon document={Icons.HISTORY_LINE} class="size-3 shrink-0"/>
					<text class="text-xs shrink-0">${entry.kind}</text><div class="flex-1"/>
					<text class="text-xs text-text-secondary shrink-0">${DateTools.format(Date.fromTime(entry.time), "%H:%M:%S")}</text></div>
				</button>
			</tooltip>
		]}<if {count < entries.length}><button variant={Ghost} onClick={_ -> shown.set(count + 20)}>More local revisions</button></if></div>;
	}
}
