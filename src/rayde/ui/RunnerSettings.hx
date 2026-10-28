package rayde.ui;

import ashui.layout.Element;
import ashui.ui.Component;

class RunnerSettings extends Component<{
	root:String,
	?target:String,
	?family:String,
	?onChanged:Void->Void
}> {
	function render():Element
		return SettingsParts.page("rayde-run-settings", <div class="flex flex-col gap-6">
  ${SettingsParts.header(Icons.PLAY_LINE, "Run", "Choose a target, framework preset and runner for this workspace.")}
  <run-configuration-settings root={props.root} target={props.target} family={props.family} onChanged={props.onChanged}/>
 </div>);
}
