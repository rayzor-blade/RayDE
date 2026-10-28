import ashui.css.Css;
import ashui.layout.Bounds;
import ashui.ui.Div;
import ashui.layout.LayoutTree;
import ashui.ui.TopLayer;
import rayde.ui.AppPreview;

@:access(rayde.ui.AppPreview)
class AppPreviewOverlayChecks {
 static function check(ok:Bool,message:String):Void if(!ok)throw message;
 static function main():Void {
  ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),Dark);
  rayde.ui.Style.use();
  var tree=new LayoutTree(),root=new Div({width:800,height:600},null,tree),entries:Array<ashui.ui.TopLayer.TopEntry>=[],contents:Array<Div>=[];
  function settle():Void for(_ in 0...8){ashui.core.render.Offscreen.advance(.025);Css.setViewport(800,600);Css.update();tree.flush();tree.computeLayout(root.node,800,600);}
  function open(tooltip:Bool,x:Float,y:Float):ashui.ui.TopLayer.TopEntry {
   var content=new Div({width:120,height:24,classes:tooltip ? ["ui-tooltip"] : []},null,tree);contents.push(content);
   var entry=TopLayer.open(tree,content,At(x,y),null,null,tooltip);entries.push(entry);settle();return entry;
  }
  var viewport=new Bounds(0,100,800,500);
  try {
   settle();
   var outside=open(true,20,10),state=AppPreview.overlays(tree,viewport);
   check(!state.covered && state.exclusions.length==0,"A tooltip above the app hid its preview");
   outside.close();settle();
   var inside=open(true,200,180);state=AppPreview.overlays(tree,viewport);
   check(!state.covered && state.exclusions.length==1,"An overlapping tooltip hid the whole app or lost its paint region");
   check(state.exclusions[0].x<=200 && state.exclusions[0].y<=180 && state.exclusions[0].width>=120,"Tooltip clip did not cover the painted bounds");
   inside.close();settle();
   var menu=open(false,20,10);state=AppPreview.overlays(tree,viewport);
   check(state.covered,"An interactive overlay lost its backdrop above the app");
   menu.close();settle();
   state=AppPreview.overlays(tree,viewport);
   check(!state.covered && state.exclusions.length==0,"Closing an overlay left the preview covered");
  }catch(error:Dynamic){for(entry in entries)entry.close();settle();for(content in contents)content.remove();root.remove();tree.dispose();throw error;}
  for(content in contents)content.remove();root.remove();tree.dispose();
  Sys.println("Preview overlays: outside and overlapping tooltips preserve the app; menus retain their backdrop; closing restores the frame");
 }
}
