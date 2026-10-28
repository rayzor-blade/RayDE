package rayde.ui;

import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.ui.Component;
import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Spinner;
import rayde.run.AppPreviewBuild;
import rayde.workspace.PageHost;

typedef AppPreviewProps = {build:AppPreviewBuild,rebuild:Void->Void,shown:Void->Bool};

/** The app owns an isolated browser frame, aligned with this tab's content rectangle. */
class AppPreview extends Component<AppPreviewProps> {
	static var serial=0;
	/** Tooltips expose only their painted region; other overlays keep their backdrop above the app. */
	static function overlays(tree:LayoutTree,bounds:ashui.layout.Bounds):{covered:Bool,exclusions:Array<{x:Float,y:Float,width:Float,height:Float}>} {
		var covered=false,exclusions=[];
		for(entry in ashui.ui.TopLayer.openEntries()) {
			if(entry.content.tree!=tree || entry.content.node==null || !entry.isOpen)continue;
			var identity=ashui.css.Identity.of(tree,entry.content.node.id);
			if(identity==null || !identity.hasClass("ui-tooltip")){covered=true;continue;}
			var box=tree.getScrolledBounds(entry.content.node);
			if(box==null || box.width<=0 || box.height<=0)continue;
			var x:Float=box.x-8,y:Float=box.y-8,width:Float=box.width+16,height:Float=box.height+16;
			if(x<bounds.x+bounds.width && x+width>bounds.x && y<bounds.y+bounds.height && y+height>bounds.y)
				exclusions.push({x:x,y:y,width:width,height:height});
		}
		return {covered:covered,exclusions:exclusions};
	}
	function render():Element {
		var surface="app-"+(++serial),last="";
		var target:Element=<div id="rayde-app-surface" class="flex-1 min-h-0 min-w-0"/>;
		var root=<div id="rayde-app-preview" class="flex flex-col flex-1 min-h-0 min-w-0">
			<div class="flex items-center justify-between gap-3 p-2 border-b border-border shrink-0">
				<div class="flex items-center gap-2 min-w-0"><if {props.build.state.get()=="building"}><spinner size={Sm}/></if><text class="text-sm text-text-secondary">${props.build.state.get()=="building" ? props.build.phase.get()+" · "+props.build.elapsed.get()+"s" : props.build.title.get()=="" ? "App Preview" : props.build.title.get()}</text></div>
				<button id="rayde-app-rebuild" variant={Ghost} size={Sm} disabled={props.build.state.get()=="building"} onClick={_ -> props.rebuild()}><icon document={Icons.RESTART_LINE} class="size-4"/>Rebuild</button>
			</div>
			<if {props.build.error.get()!=""}><div class="p-3 overflow-y-auto"><text class="text-error text-sm">${props.build.error.get()}</text></div></if>
			${target}
		</div>;
		var hook:LayoutTree->Void=tree -> {
			if(tree!=root.tree||PageHost.bridge==null)return;
			var artifact=props.build.artifact.get(),bounds=tree.getScrolledBounds(target.node),viewport=tree.root==null ? null : tree.getBounds(tree.root);
			if(artifact==null||bounds==null||viewport==null)return;
			var overlay=overlays(tree,bounds);
			var visible=props.shown()&&!overlay.covered&&bounds.width>0&&bounds.height>0;
			var request:Dynamic={surface:surface,preview:artifact.preview,arguments:artifact.arguments ?? [],x:bounds.x,y:bounds.y,width:bounds.width,height:bounds.height,viewportWidth:viewport.width,viewportHeight:viewport.height,visible:visible,exclusions:overlay.exclusions};
			var key=haxe.Json.stringify(request);
			if(key==last)return;last=key;
			PageHost.bridge.notify("page.preview",request);
		};
		LayoutTree.settledHooks.push(hook);
		LayoutTree.flushHooks.push(hook);
		Owner.onCleanup(() -> {LayoutTree.settledHooks.remove(hook);LayoutTree.flushHooks.remove(hook);if(PageHost.bridge!=null)PageHost.bridge.notify("page.preview",{surface:surface,remove:true});});
		return root;
	}
}
