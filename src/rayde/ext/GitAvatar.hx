package rayde.ext;

import ashui.layout.Element;
import ashui.layout.Prop;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.reactive.Watch;
import ashui.types.Bitmap;
import ashui.ui.Component;

/** The avatar's decoded pixels live only as long as its visible presentation. */
class GitAvatar extends Component<{profile:Signal<Dynamic>, network:Bool}> {
	function render():Element {
		var photo = Signal.make((null:Bitmap)), initials = Signal.make("?");
		var active:Owner = null;
		var scope = Owner.current;
		new Watch(() -> haxe.Json.stringify(props.profile.get()), _ -> {
			photo.set(null);
			if (active != null) active.dispose();
			var data = props.profile.get();
			var name:String = data == null || data.author == null ? "" : data.author;
			var words = ~/\s+/g.split(StringTools.trim(name));
			initials.set(name == "" ? "?" : (words[0].substr(0, 1) + (words.length > 1 ? words[words.length - 1].substr(0, 1) : "")).toUpperCase());
			scope.run(() -> active = new Owner(tree));
			active.run(() -> GitProfiles.observe(data, props.network, result -> {
				if (result == null) return;
				try {
					var bitmap = Bitmap.fromBytes(result.bytes);
					Owner.onCleanup(bitmap.dispose);
					bitmap.shrink(64);
					photo.set(bitmap);
				} catch (_:Dynamic) {}
			}));
		});
		Owner.onCleanup(() -> { if (active != null) active.dispose(); });
		function picture(bitmap:Bitmap):Element {
			var image = new ashui.ui.Image(bitmap, {fit:Contain});
			image.node.set(Prop.WidthPercent, (1:Single));
			image.node.set(Prop.HeightPercent, (1:Single));
			return image;
		}
		return <div class="rayde-git-avatar">
			<if {photo.get() != null}>${picture(photo.get())}
			<else><text>{initials}</text></if>
		</div>;
	}
}
