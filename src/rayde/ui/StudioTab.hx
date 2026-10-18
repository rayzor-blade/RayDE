package rayde.ui;

import ashui.layout.Element;
import ashui.ui.Component;
import ashui.ui.Div;
import ashui.ui.Ref;
import rayde.ext.Studio;

typedef StudioTabProps = {studio:Studio, root:Int};

/** A view the extension presented as a tab: the nodes of one mounted root, placed in the editor area. */
class StudioTab extends Component<StudioTabProps> {
	function render():Element {
		var surface = new Ref<Div>();
		var body = <div ref={surface} id={"rayde-ext-tab-" + props.root} class="rayde-card rayde-studio-surface flex flex-col flex-1 min-h-0 min-w-0 overflow-auto"/>;
		var node = surface.get().node, studio = props.studio;
		studio.attach(node, props.root);
		ashui.reactive.Owner.onCleanup(() -> studio.detach(node));
		return body;
	}
}
