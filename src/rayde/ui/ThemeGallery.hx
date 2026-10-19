package rayde.ui;

import ashui.components.Alert;
import ashui.components.Badge;
import ashui.components.Button;
import ashui.components.Checkbox;
import ashui.components.Progress;
import ashui.components.Slider;
import ashui.components.ToggleSwitch;
import ashui.layout.Element;
import ashui.ui.Component;

/** Components as the theme in use draws them: buttons, badges, controls, alerts and the text scale. */
class ThemeGallery extends Component<{}> {
	function render():Element
		return <div id="rayde-theme-samples" class="flex flex-col gap-5">
			<div class="flex items-center gap-2 flex-wrap">
				<button variant={Primary} size={Sm}>Primary</button>
				<button variant={Secondary} size={Sm}>Secondary</button>
				<button variant={Outline} size={Sm}>Outline</button>
				<button variant={Ghost} size={Sm}>Ghost</button>
				<button variant={Destructive} size={Sm}>Destructive</button>
				<button variant={Link} size={Sm}>Link</button>
				<button variant={Primary} size={Sm} disabled={true}>Disabled</button>
			</div>
			<div class="flex items-center gap-2 flex-wrap">
				<badge variant={Primary}>primary</badge>
				<badge variant={Secondary}>secondary</badge>
				<badge variant={Success}>success</badge>
				<badge variant={Warning}>warning</badge>
				<badge variant={Destructive}>destructive</badge>
				<badge variant={Primary} appearance={Solid}>solid</badge>
				<badge variant={Primary} appearance={Outline}>outline</badge>
			</div>
			<div class="flex items-center gap-5">
				<input height={32} placeholder="Input" class="rayde-control"/>
				<toggle-switch checked={true} size={Sm}/>
				<checkbox checked={true}/>
				<slider value={40.} min={0} max={100} class="rayde-control-narrow"/>
				<progress value={60.} max={100} class="rayde-control-narrow"/>
			</div>
			<div class="flex flex-col gap-2">
				<alert variant={Info}><alert-title>Info</alert-title><alert-description>Build finished with 2 warnings.</alert-description></alert>
				<alert variant={Success}><alert-title>Success</alert-title><alert-description>Theme saved.</alert-description></alert>
				<alert variant={Warning}><alert-title>Warning</alert-title><alert-description>Font file not found.</alert-description></alert>
				<alert variant={Destructive}><alert-title>Error</alert-title><alert-description>Invalid JSON at line 4.</alert-description></alert>
			</div>
			<div class="rayde-card flex flex-col gap-1 p-4">
				<text class="text-xs text-text-tertiary">text-xs</text>
				<text class="text-sm text-text-secondary">text-sm secondary</text>
				<text class="text-base text-text-primary">text-base primary</text>
				<text class="text-lg font-semibold text-text-primary">text-lg semibold</text>
				<text class="text-2xl font-semibold tracking-tighter text-text-primary">text-2xl</text>
				<text class="rayde-font-mono text-sm text-text-secondary">mono: let x = 42;</text>
				<text class="rayde-font-serif text-base text-text-secondary">serif: Sphinx of black quartz</text>
			</div>
		</div>;
}
