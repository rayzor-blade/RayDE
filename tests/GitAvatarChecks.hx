import ashui.core.render.Offscreen;
import ashui.core.render.Snapshot;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.theme.ThemeState;
import ashui.theme.themes.RestrainedTheme;
import ashui.types.Bitmap;
import rayde.ext.GitAvatar;
import rayde.ext.GitProfiles;

@:access(rayde.ext.GitProfiles)
@:access(ashui.ui.Image)
@:access(ashui.types.Bitmap)
class GitAvatarChecks {
	static function main():Void {
		var cache = 'bin/git-avatar-checks-${Std.random(0x3fffffff)}';
		GitProfiles.directory = () -> cache;
		var bytes = sys.io.File.getBytes("tests/fixtures/images/sample.jpg");
		GitProfiles.request = (url, _) -> url.indexOf("api.github.com") >= 0
			? haxe.io.Bytes.ofString('[{"author":{"avatar_url":"https://avatars.githubusercontent.com/u/1"}}]') : bytes;
		for (dark in [true, false]) {
			ThemeState.init(RestrainedTheme.bundle(), dark ? Dark : Light);
			rayde.ui.Style.use();
			var tree = new LayoutTree(), stop:Void->Void = null;
			var profile = Signal.make(({id:[for (_ in 0...40) "a"].join(""), remote:"https://github.com/fixture/public.git", author:"Public Author", email:"avatar@example.test"}:Dynamic));
			var root = Owner.root(tree, cleanup -> {
				stop = cleanup;
				return <div id="rayde" width={360} height={120} class="p-4 bg-surface">
					<div class="flex flex-row items-center gap-3"><div width={32} height={32}>${new GitAvatar({profile:profile, network:true})}</div><text class="text-text-primary">Public Author</text></div>
				</div>;
			});
			function settle():Void {
				Offscreen.advance(1/60); Css.setViewport(360, 120); Css.update(); tree.flush(); tree.computeLayout(root.node, 360, 120);
			}
			var deadline = haxe.Timer.stamp() + 5;
			while (Css.query(tree, root.node.id, ".rayde-git-avatar img").length == 0 && haxe.Timer.stamp() < deadline) { settle(); Sys.sleep(.005); }
			var bitmap:Bitmap = null;
			for (image in ashui.ui.Image.byNode) if (image.tree == tree) bitmap = image.bitmap;
			if (bitmap == null || bitmap.width > 64 || bitmap.height > 64) throw "Public avatar failed to decode into a bounded image";
			for (_ in 0...10) settle();
			var avatarBounds = tree.getBounds(new ashui.layout.Node(Css.query(tree, root.node.id, ".rayde-git-avatar")[0]));
			var imageBounds = tree.getBounds(new ashui.layout.Node(Css.query(tree, root.node.id, ".rayde-git-avatar img")[0]));
			if (avatarBounds.width != 32 || avatarBounds.height != 32 || imageBounds.width != 32 || imageBounds.height != 32) throw "Avatar image escaped its fixed circular frame: " + haxe.Json.stringify({avatar:avatarBounds, image:imageBounds});
			Snapshot.capture('git-avatar-${dark ? "dark" : "light"}', tree, root.node, 360, 120, dark ? 0x0d1117 : 0xf5f6fa);
			profile.set({id:profile.get().id, remote:"file:///local/repo", author:"Local Author", email:"local@example.test"}); settle();
			if (!bitmap.disposed || Css.query(tree, root.node.id, ".rayde-git-avatar img").length != 0) throw "Replacing an avatar retained its decoded pixels";
			stop(); tree.dispose();
			if (GitProfiles.listeners.length != 0 || GitProfiles.hooked) throw "Closing the avatar retained its owner in the profile service";
		}
		Sys.println("Git avatars: decoded public images, bounded dimensions, themed rendering and pixel/listener release");
	}
}
