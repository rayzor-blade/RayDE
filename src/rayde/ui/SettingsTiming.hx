package rayde.ui;

import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;

/** Settings navigation timing; safe to enable with RAYDE_SETTINGS_TIMING=1. */
class SettingsTiming {
	static final enabled = Sys.getEnv("RAYDE_SETTINGS_TIMING") == "1";
	static var requested = 0.;
	public static function request():Void if (enabled) requested = haxe.Timer.stamp();

	public static function build(id:String, make:Void->Element):Element {
		if (!enabled) return make();
		var start = haxe.Timer.stamp(), element = make(), built = haxe.Timer.stamp(), active = true;
		var hook:LayoutTree->Bool = null;
		function remove():Void {
			active = false;
			LayoutTree.layoutHooks.remove(hook);
		}
		hook = tree -> {
			if (!active || tree != element.tree) return false;
			var bounds = tree.getBounds(element.node);
			if (bounds == null || bounds.width <= 0 || bounds.height <= 0) return false;
			Sys.println("settings-ready:" + haxe.Json.stringify({id:id, buildMs:(built - start) * 1000,
				readyMs:(haxe.Timer.stamp() - (requested == 0 ? start : requested)) * 1000,
				keyRows:ashui.css.Css.query(tree, element.node.id, ".rayde-key-row").length,
				libraryRows:ashui.css.Css.query(tree, element.node.id, ".rayde-lib-row").length}));
			active = false; return false;
		};
		LayoutTree.layoutHooks.push(hook); Owner.onCleanup(remove);
		return element;
	}
}
