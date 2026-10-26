package rayde.ui;

import rayde.workspace.Fs;
import ashui.components.Icon;
import ashui.layout.Element;
import ashui.reactive.Owner;
import ashui.svg.SvgDocument;
import ashui.ui.Component;
import rayde.project.ProjectTemplates.ProjectTemplate;

/** Brand assets keep their original colours; raster pixels belong to the mounted card. */
class ProjectLogo extends Component<{template:ProjectTemplate}> {
	static final haxeLogo = SvgDocument.embed("assets/project-logos/haxe.svg");
	static final rayzor = SvgDocument.embed("extensions/rayzor/logo.svg");
	static final javascript = SvgDocument.embed("assets/project-logos/javascript.svg");
	static final hashlink = SvgDocument.embed("assets/project-logos/hashlink.svg");
	static final openfl = SvgDocument.embed("assets/project-logos/openfl.svg");
	static final flixel = SvgDocument.embed("assets/project-logos/flixel.svg");
	static final lime = SvgDocument.embed("assets/project-logos/lime.svg");
	static final ashuiLight = SvgDocument.embed("assets/project-logos/ashui-icon-light.svg");
	static final ashuiDark = SvgDocument.embed("assets/project-logos/ashui-icon-dark.svg");

	function render():Element {
		var template = props.template;
		if (template.owner != null) {
			var icon = template.iconPath == null ? ViewIcons.named(null, template.icon) : try SvgDocument.parse(Fs.getContent(template.iconPath)) catch (_:Dynamic) null;
			return vector(icon ?? Icons.CODE_BOX_LINE);
		}
		return switch template.id {
			case "ash": raster(ProjectLogoAssets.bytes("assets/project-logos/ash.png"));
			case "ashui": <for {dark in [darkScheme()]}>${vector(dark ? ashuiDark : ashuiLight)}</for>;
			case "heaps": raster(ProjectLogoAssets.bytes("assets/project-logos/heaps.png"));
			case "ceramic": <div class="rayde-project-ceramic-logo">${raster(ProjectLogoAssets.bytes("assets/project-logos/ceramic.png"))}</div>;
			case "hxml" | "haxelib": vector(haxeLogo);
			case "rayzor": vector(rayzor);
			case "javascript": vector(javascript);
			case "hashlink": vector(hashlink);
			case "openfl": vector(openfl);
			case "flixel": vector(flixel);
			case "lime": vector(lime);
			case _: vector(Icons.CODE_BOX_LINE);
		};
	}

	function darkScheme():Bool {
		var state = ashui.theme.ThemeState.get();
		state.revision.get();
		return state.scheme() == ashui.theme.ColorScheme.Dark;
	}

	function vector(document:SvgDocument):Element return <icon document={document} class="rayde-project-template-icon"/>;
	function raster(bytes:haxe.io.Bytes):Element {
		var bitmap = ashui.types.Bitmap.fromBytes(bytes);
		Owner.onCleanup(bitmap.dispose);
		bitmap.shrink(144);
		var image = new ashui.ui.Image(bitmap, {width:26, height:26, fit:Contain});
		ashui.css.Identity.of(image.tree, image.node.id).addClasses(["rayde-project-template-image"]);
		return image;
	}
}
