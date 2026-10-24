import ashui.core.UiContext;
import ashui.css.Css;
import ashui.css.Identity;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.ext.ExtensionStyles;
import rayde.ext.Manifest;

/** Mounted CSS uses the native cascade, with independent owners and window contexts. */
@:access(ashui.css.Css)
class ExtensionStylesChecks {
	static function check(ok:Bool, message:String):Void {
		if (!ok)
			throw message;
	}

	static function main():Void
		run();

	public static function run():Void {
		var root = Sys.getCwd() + "bin/style-lifecycle-" + Std.random(0x3fffffff);
		function manifest(folder:String, color:String):Manifest {
			var dir = root + "/" + folder;
			sys.FileSystem.createDirectory(dir);
			sys.io.File.saveContent(dir + "/main.rays", "");
			sys.io.File.saveContent(dir + "/theme.css", '.chrome { color: $color; animation-name: spin; }');
			sys.io.File.saveContent(dir + "/animation.css", '@keyframes spin { from { opacity: 0; } to { opacity: 1; } }');
			sys.io.File.saveContent(dir + "/demo.rayext", '{"id":"same-id","main":"main.rays","styles":["theme.css","animation.css"]}');
			return Manifest.read(dir + "/demo.rayext");
		}
		var first = manifest("first", "#abcdef"),
			second = manifest("second", "#fedcba");
		var a = new UiContext(), b = new UiContext();
		var tree:LayoutTree = null,
			rootView:Element = null,
			stop:Void->Void = null;
		var releaseFirst:Void->Void = null,
			releaseTwin:Void->Void = null,
			releaseSecond:Void->Void = null;
		var errors:Array<String> = [];
		function report(message:String):Void
			errors.push(message);
		function count():Int
			return Css.sheets.length;
		function color(selector:String):Null<String> {
			tree.flush();
			tree.computeLayout(rootView.node, 600, 400);
			var nodes = Css.query(tree, rootView.node.id, selector);
			check(nodes.length == 1, 'missing style target $selector');
			var value = Css.resolved(Identity.of(tree, nodes[0]), "color");
			return value == null ? null : value.toLowerCase();
		}
		a.run(() -> {
			Css.load("#rayde .chrome { color: #111111; } @keyframes spin { from { opacity: 0.6; } to { opacity: 0.8; } }", "application.css");
			tree = new LayoutTree();
			rootView = Owner.root(tree, dispose -> {
				stop = dispose;
				function chrome(?id:String):Element {
					var element = <div id={id}/>;
					Identity.of(tree, element.node.id).addClasses(["chrome"]);
					return element;
				}
				var one = <div id="first">${chrome()}</div>;
				var two = <div id="second">${chrome()}</div>;
				ExtensionStyles.mark(one, first);
				ExtensionStyles.mark(two, second);
				return <div id="rayde">{one}{two}${chrome("outside")}</div>;
			});
			var baseline = count();
			releaseFirst = ExtensionStyles.use(first, report);
			releaseTwin = ExtensionStyles.use(first, report);
			releaseSecond = ExtensionStyles.use(second, report);
			check(count() == baseline + 2, "each extension sheet must be registered once, regardless of view count");
			check(color("#first .chrome") == "#abcdef" && color("#second .chrome") == "#fedcba",
				"same extension ids from different workspaces shared their overrides");
			check(color("#outside") == "#111111", "extension styles escaped their wrapper");
			function animation(selector:String):String
				return Css.resolved(Identity.of(tree, Css.query(tree, rootView.node.id, selector)[0]), "animation-name");
			var one = animation("#first .chrome"),
				two = animation("#second .chrome");
			check(one != two && StringTools.startsWith(one, "rayde-ext-") && StringTools.startsWith(two, "rayde-ext-"),
				"keyframes collided between workspace overrides");
			check(ashui.css.NativeCascade.keyframes(one) != null && ashui.css.NativeCascade.keyframes(two) != null,
				"animation names did not resolve to the other stylesheet's keyframes");
			var globalFrames = ashui.css.NativeCascade.keyframes("spin");
			check(globalFrames != null && Std.parseFloat(globalFrames.frames[0].declarations[0].value) == .6,
				"extension keyframes replaced the application's animation");
			check(errors.length == 0, 'valid styles reported errors: $errors');
			for (hex in ["#aabbcc", "#abcdef", "#123456"]) {
				sys.io.File.saveContent(first.root + "/theme.css", '.chrome { color: $hex; }');
				ExtensionStyles.refresh(first, report);
				check(color("#first .chrome") == hex, "same-size immediate stylesheet reload did not reach the native cascade");
				check(count() == baseline + 2, "reload accumulated sheets");
			}
			for (bad in [".chrome { color: red", "/* unclosed comment"]) {
				sys.io.File.saveContent(first.root + "/theme.css", bad);
				ExtensionStyles.refresh(first, report);
				check(errors.length > 0 && color("#first .chrome") == "#123456", "malformed CSS replaced the last working sheet");
				var reported = errors.length;
				ExtensionStyles.refresh(first, report);
				check(errors.length == reported, "unchanged invalid CSS repeatedly reported the same error");
			}
			sys.FileSystem.deleteFile(first.root + "/theme.css");
			ExtensionStyles.refresh(first, report);
			check(color("#first .chrome") == "#123456", "missing CSS discarded the last working style");
			sys.io.File.saveContent(first.root + "/theme.css", ".chrome { color: #abcdef; }");
			ExtensionStyles.refresh(first, report);
			var beforeLarge = errors.length;
			sys.io.File.saveContent(first.root + "/theme.css", StringTools.rpad("/*", " ", ExtensionStyles.LIMIT + 1));
			ExtensionStyles.refresh(first, report);
			check(errors.length > beforeLarge && color("#first .chrome") == "#abcdef", "oversized CSS replaced the working sheet");
			sys.io.File.saveContent(first.root + "/theme.css", ".chrome { color: #abcdef; }");
			ExtensionStyles.refresh(first, report);
			releaseFirst();
			releaseFirst();
			check(count() == baseline + 2 && color("#first .chrome") == "#abcdef", "disposing one view removed another's sheet");
		});
		// The same manifest must be installed separately in each window.
		var otherRelease = b.run(() -> {
			check(count() == 0, "window inherited another window's extension sheet");
			var release = ExtensionStyles.use(first, report);
			check(count() == 1, "second window did not install its own sheet");
			return release;
		});
		// Disposers run in their creation context even if another window is active.
		b.run(() -> {
			releaseTwin();
			check(count() == 1, "closing a view removed the other window's stylesheet");
		});
		a.run(() -> {
			check(count() == 2 && color("#first .chrome") == "#111111", "last view left an extension sheet in force");
			// A new manifest object cannot change what an old view's disposer owns.
			sys.io.File.saveContent(second.file, '{"id":"same-id","main":"main.rays","styles":[]}');
			var changed = Manifest.read(second.file);
			var emptyRelease = ExtensionStyles.use(changed, report);
			releaseSecond();
			emptyRelease();
			check(count() == 1 && color("#second .chrome") == "#111111", "manifest replacement or empty styles leaked the old sheet");
			stop();
			tree.dispose();
		});
		otherRelease();
		b.run(() -> check(count() == 0, "last window retained its sheet"));
		a.clear();
		b.clear();
		// Canonical path checks also apply to links, not only ../ in a manifest.
		var containment = new UiContext();
		if (Sys.systemName() != "Windows")
			containment.run(() -> {
				var outside = root + "/outside.css";
				sys.io.File.saveContent(outside, ".chrome { color: red; }");
				sys.FileSystem.deleteFile(first.root + "/theme.css");
				check(Sys.command("ln", ["-s", outside, first.root + "/theme.css"]) == 0, "cannot create CSS containment fixture");
				var before = errors.length,
					release = ExtensionStyles.use(first, report);
				check(count() == 0 && errors.length > before, "stylesheet symlink escaped the extension directory");
				release();
			});
		containment.clear();
		Sys.println("Extension stylesheet lifecycle: native overrides, reload, malformed input, view disposal, workspace/window isolation and path containment passed");
	}
}
