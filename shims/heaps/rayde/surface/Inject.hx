package rayde.surface;

import haxe.macro.Compiler;
import haxe.macro.Context;
import haxe.macro.Expr;

/**
 * Build step that presents any Heaps app in the Surface Preview without changing its source: `--macro rayde.surface.Inject.apply()` wraps
 * `hxd.App.mainLoop` so every frame is delivered input before and captured after.
 */
class Inject {
	public static function apply():Void {
		Compiler.addMetadata("@:build(rayde.surface.Inject.build())", "hxd.App");
	}

	public static function build():Array<Field> {
		var fields = Context.getBuildFields();
		for (field in fields) {
			if (field.name != "mainLoop") continue;
			field.name = "raydeMainLoop";
		}
		var wrapper:Field = {
			name: "mainLoop",
			access: [],
			pos: Context.currentPos(),
			kind: FFun({args: [], ret: null, expr: macro {
				if (rayde.surface.HeapsSurface.before(this)) {
					raydeMainLoop();
					rayde.surface.HeapsSurface.after(this);
				}
			}})
		};
		fields.push(wrapper);
		return fields;
	}
}
