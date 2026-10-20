package rayde.ui;

import ashui.components.Collapsible;
import ashui.components.Resizable;
import ashui.layout.Element;
import ashui.layout.Prop;
import ashui.reactive.Signal;
import ashui.reactive.Computed;
import ashui.ui.Div;
import ashui.components.Icon;
import ashui.ui.Text;

/** Section state belongs to the workbench; mounted content belongs to the open section. */
class ExplorerSection {
	public final opened:Signal<Bool>;
	public final size:Signal<Float>;
	var expanded:Float;
	public final id:String;

	public function new(id:String, open:Bool, height:Float) {
		this.id = id; expanded = height;
		opened = Signal.make(open); size = Signal.make(open ? height : 28.);
	}

	public function panel(title:String, body:Void->Element, tools:Array<Element>):ResizablePanel {
		var arrow = new Icon({document:Icons.ARROW_RIGHT_S_LINE});
		arrow.node.set(Prop.Width, (14:Single)); arrow.node.set(Prop.Height, (14:Single));
		arrow.node.set(Prop.Transform, Computed.make(() -> new ashui.types.Transform(0, 0, opened.get() ? 90 : 0)));
		var trigger = new CollapsibleTrigger({id:"rayde-explorer-toggle-" + id}, [arrow, new Text(title, {fontSize:12, wrap:false})]);
		var content = new CollapsibleContent({id:"rayde-explorer-content-" + id}, [<if {opened.get()}>${body()}</if>]);
		content.node.set(Prop.MinHeight, (0:Single)); content.node.set(Prop.FlexBasis, (0:Single));
		content.node.set(Prop.FlexGrow, Computed.make(() -> (opened.get() ? 1. : 0. : Single)));
		var panel:ResizablePanel = null;
		var controls = <div class="rayde-explorer-section-tools flex items-center gap-1">{tools}</div>;
		var box = new Collapsible({id:"rayde-explorer-section-" + id, open:opened, onOpenChange:open -> {
			if (!open) { expanded = size.get(); size.set(28); } else size.set(expanded);
			panel.props.maxSize = open ? null : 28;
		}}, [trigger, controls, content]);
		box.node.set(Prop.HeightPercent, (1:Single)); box.node.set(Prop.MinHeight, (0:Single));
		panel = new ResizablePanel({id:"rayde-explorer-panel-" + id, size:size, minSize:28, maxSize:opened.get() ? null : 28}, [box]);
		panel.node.set(Prop.MaxHeight, Computed.make(() -> (opened.get() ? Math.NaN : 28. : Single)));
		return panel;
	}
}
