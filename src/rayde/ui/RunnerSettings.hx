package rayde.ui;

import ashui.components.Select;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.project.ProjectRunner;

class RunnerSettings extends Component<{root:String, ?onChanged:Void->Void}> {
	final selected = Signal.make("auto");
	function render():Element {
		selected.set(ProjectRunner.preference(props.root));
		return SettingsParts.page("rayde-run-settings", <div class="flex flex-col gap-6">
			${SettingsParts.header(Icons.PLAY_LINE, "Run", "Choose the default runner for this project's HashLink bytecode.")}
			${SettingsParts.card("rayde-runner-card", "Default runner", "Automatic uses Ash on Apple Silicon and HashLink on other platforms. Ash starters select Ash explicitly.", [
				SettingsParts.field("Runner", "Saved for this workspace. Applies to the next run.", <select id="rayde-runner-default" value={selected} class="rayde-control-wide" onChange={save}>
					<select-item value="auto">${"Automatic (" + ProjectRunner.label(ProjectRunner.defaultHashlink()) + ")"}</select-item>
					<select-item value="ash">Ash</select-item>
					<select-item value="hashlink">HashLink (hl)</select-item>
				</select>)
			])}
		</div>);
	}
	function save(value:String):Void {
		var section = rayde.settings.Store.section(props.root, "run"); section.runner = value;
		rayde.settings.Store.save(props.root, "run", section); selected.set(value);
		if (props.onChanged != null) props.onChanged();
	}
}
