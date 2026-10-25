package rayde.ui;

import rayde.workspace.Fs;
import ashui.canvaskit.CanvasKit;
import ashui.canvaskit.Viewport2D;
import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Tooltip;
import ashui.css.Identity;
import ashui.input.Interaction;
import ashui.layout.Element;
import ashui.layout.LayoutTree;
import ashui.layout.Prop;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import ashui.reactive.Watch;
import ashui.ui.Component;
import ashui.ui.Div;

typedef ImageViewState = {panX:Float, panY:Float, zoom:Float, fit:Bool, light:Bool};
typedef ImagePreviewProps = {file:String, state:ImageViewState, ?source:Signal<String>, ?onEdit:Void->Void};

/** The active image owns its decoded pixels or vector document; tabs retain only view coordinates. */
class ImagePreview extends Component<ImagePreviewProps> {
	public var viewport(default, null):Viewport2D;
	var bitmap:ashui.types.Bitmap;
	var dimensions = {width:0., height:0.};
	var area:Div;
	final info = Signal.make("");
	final available = Signal.make(false);
	final reload = Signal.make(0);
	final light = Signal.make(false);

	public static function isSvg(file:String):Bool return haxe.io.Path.extension(file).toLowerCase() == "svg";
	public static function isRaster(file:String):Bool return ["png", "jpg", "jpe", "jpeg", "bmp", "gif", "ico", "webp", "avif"].indexOf(haxe.io.Path.extension(file).toLowerCase()) >= 0;
	static function extraCodec(file:String):Bool return ["bmp", "gif", "ico", "avif"].indexOf(haxe.io.Path.extension(file).toLowerCase()) >= 0;
	public static function supports(file:String):Bool return isSvg(file) || isRaster(file);
	public static function state():ImageViewState return {panX:0, panY:0, zoom:1, fit:true, light:false};

	function render():Element {
		var saved = props.state;
		viewport = new Viewport2D(saved.zoom, saved.panX, saved.panY);
		viewport.minZoom = .01; viewport.maxZoom = 32;
		light.set(saved.light);
		Owner.onCleanup(() -> {
			saved.panX = viewport.panX.get(); saved.panY = viewport.panY.get(); saved.zoom = viewport.zoom.get(); saved.light = light.get();
			viewport.stop();
		});
		return <div id="rayde-image-preview" class="flex flex-col flex-1 min-h-0 min-w-0">
			<div class="rayde-image-tools flex items-center gap-1 shrink-0 px-3 py-2">
				<text id="rayde-image-info" class="text-xs text-text-secondary flex-1 min-w-0">${info.get()}</text>
				${action("rayde-image-out", "Zoom out", Icons.ZOOM_OUT_LINE, () -> zoom(.8))}
				<tooltip label="Actual size (100%)" side="bottom"><button id="rayde-image-actual" size={Sm} variant={Ghost} disabled={!available.get()} onClick={_ -> actual()}><text>${Math.round(viewport.zoom.get()*100) + "%"}</text></button></tooltip>
				${action("rayde-image-in", "Zoom in", Icons.ZOOM_IN_LINE, () -> zoom(1.25))}
				${action("rayde-image-fit", "Fit image", Icons.ASPECT_RATIO_LINE, fit)}
				${action("rayde-image-background", "Toggle light background", Icons.CONTRAST_2_LINE, () -> light.set(!light.get()), false)}
				${action("rayde-image-reload", "Refresh image", Icons.REFRESH_LINE, () -> reload.set(reload.get()+1), false)}
				<if {props.onEdit != null}>${action("rayde-image-edit", "Open in editor", Icons.CODE_S_SLASH_LINE, props.onEdit, false)}</if>
			</div>
			<for {input in [{text:props.source == null ? null : props.source.get(), revision:reload.get()}]}>${surface(input.text)}</for>
		</div>;
	}

	function action(id:String, label:String, icon:ashui.svg.SvgDocument, run:Void->Void, needsImage = true):Element {
		return <tooltip label={label} side="bottom"><button id={id} variant={Ghost} size={Icon} class="rayde-panel-button" disabled={needsImage && !available.get()} onClick={_ -> run()}><icon document={icon} class="size-4"/></button></tooltip>;
	}

	function surface(source:Null<String>, ?converted:haxe.io.Bytes):Element {
		available.set(false);
		try {
			var picture:Element, file = props.file, size = Fs.stat(file).size;
			if (converted == null && extraCodec(file)) {
				info.set(haxe.io.Path.withoutDirectory(file));
				var result = Signal.make((null:{bytes:Null<haxe.io.Bytes>, error:Null<String>}));
				Owner.onCleanup(RasterDecode.start(Fs.getBytes(file), haxe.io.Path.extension(file).toLowerCase() == "avif", (bytes, error) -> result.set({bytes:bytes,error:error})));
				return <for {decoded in [result.get()]}>{
					if (decoded == null) <div id="rayde-image-loading" class="flex flex-1 items-center justify-center"><text class="text-sm text-text-secondary">Loading image…</text></div>;
					else if (decoded.error != null) failure(decoded.error);
					else {
						var bytes = decoded.bytes;
						decoded.bytes = null;
						surface(null, bytes);
					}
				}</for>;
			}
			if (isSvg(file)) {
				var doc = SvgDocuments.acquire(source == null ? Fs.getContent(file) : source);
				Owner.onCleanup(() -> SvgDocuments.release(doc));
				dimensions = {width:doc.width, height:doc.height};
				picture = new ashui.ui.Svg(doc, {width:(doc.width:Single), height:(doc.height:Single)});
			} else {
				var image = ashui.types.Bitmap.fromBytes(converted == null ? Fs.getBytes(file) : converted);
				// Converted PNG bytes are transient; a remounted preview decodes its original file again.
				if (converted != null) @:privateAccess image.encoded = null;
				bitmap = image;
				Owner.onCleanup(() -> { image.dispose(); if (bitmap == image) bitmap = null; });
				dimensions = {width:image.width, height:image.height};
				picture = new ashui.ui.Image(image);
			}
			var w = dimensions.width, h = dimensions.height;
			if (!Math.isFinite(w) || !Math.isFinite(h) || w <= 0 || h <= 0) throw "Image has no usable dimensions";
			info.set('$w × $h · ' + haxe.io.Path.extension(file).toUpperCase() + ' · ${Math.ceil(size/1024)} KB' + (haxe.io.Path.extension(file).toLowerCase() == "gif" ? " · First frame" : ""));
			area = new Div({position:ashui.types.Style.Position.Relative, flexGrow:1, flexBasis:0, minHeight:0, overflow:ashui.types.Style.Overflow.Hidden});
			Identity.of(area.tree, area.node.id).setId("rayde-image-surface").setClasses(["rayde-image-surface"]);
			Identity.of(area.tree, area.node.id).bindAttribute("data-light", ashui.reactive.Computed.make(() -> light.get() ? "true" : null));
			picture.node.set(Prop.Position, ashui.types.Style.Position.Absolute);
			picture.node.set(Prop.Left, (0:Single)); picture.node.set(Prop.Top, (0:Single));
			picture.node.set(Prop.PointerEvents, ashui.types.Style.PointerEvents.None);
			area.appendChild(picture);
			var kit = new CanvasKit({id:"rayde-image-canvas", viewport:viewport, background:new ashui.canvaskit.Background2D(None)});
			kit.momentumDecay = 0;
			kit.node.set(Prop.Position, ashui.types.Style.Position.Absolute);
			kit.node.set(Prop.Left, (0:Single)); kit.node.set(Prop.Top, (0:Single));
			kit.node.set(Prop.WidthPercent, (1:Single)); kit.node.set(Prop.HeightPercent, (1:Single));
			Interaction.of(kit.node).onWheel(_ -> props.state.fit = false).onPointerDown(_ -> props.state.fit = false);
			area.appendChild(kit);
			new Watch(() -> ({x:viewport.panX.get(), y:viewport.panY.get(), z:viewport.zoom.get()}), p ->
				picture.node.set(Prop.Transform, new ashui.types.Transform(p.x*p.z+(p.z-1)*w/2, p.y*p.z+(p.z-1)*h/2, 0, p.z, p.z)));
			var lastW = 0., lastH = 0.;
			var hook:LayoutTree->Void = tree -> {
				if (tree != area.tree) return;
				var b = tree.getBounds(area.node);
				if (b != null && b.width > 0 && b.height > 0 && (b.width != lastW || b.height != lastH)) {
					lastW = b.width; lastH = b.height;
					if (props.state.fit) fit();
				}
			};
			LayoutTree.settledHooks.push(hook);
			Owner.onCleanup(() -> LayoutTree.settledHooks.remove(hook));
			available.set(true);
			return area;
		} catch (error:Dynamic) {
			info.set(haxe.io.Path.withoutDirectory(props.file));
			return failure(Std.string(error));
		}
	}

	function failure(error:String):Element return <div id="rayde-image-error" class="flex flex-col items-center justify-center flex-1 gap-3 p-6"><icon document={Icons.IMAGE_LINE} class="size-8 text-text-secondary"/><text>Unable to preview this image</text><text class="text-sm text-text-secondary">${error}</text></div>;

	function zoom(factor:Float):Void {
		var b = area.tree.getBounds(area.node);
		if (b != null) { props.state.fit = false; viewport.stop(); viewport.zoomAt(b.width/2, b.height/2, factor); }
	}

	function actual():Void {
		var b = area.tree.getBounds(area.node);
		if (b != null) { props.state.fit = false; viewport.moveTo((b.width-dimensions.width)/2, (b.height-dimensions.height)/2, 1, 0); }
	}

	function fit():Void {
		var b = area.tree.getBounds(area.node);
		if (b == null || b.width <= 0 || b.height <= 0) return;
		props.state.fit = true;
		var z = Math.max(viewport.minZoom, Math.min(1, Math.min(Math.max(1,b.width-48)/dimensions.width, Math.max(1,b.height-48)/dimensions.height)));
		viewport.moveTo(b.width/2/z-dimensions.width/2, b.height/2/z-dimensions.height/2, z, 0);
	}
}
