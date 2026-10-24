package rayde.ui;

import ashui.core.render.CanvasFrame;
import ashui.core.render.Offscreen;
import ashui.core.render.SceneShader;
import ashui.layout.DisplayList;
import ashui.layout.Element;
import ashui.layout.Node;
import gpu.GpuBindGroup;
import gpu.GpuBindings;
import gpu.GpuTexture;
import gpu.GpuTextureView;
import gpu.GpuTextureViewDescriptor;

/** One GPU thumbnail per gesture, released on drop or cancellation. */
class EditorTabSnapshot {
	public final width:Int;
	public final height:Int;

	var texture:Null<GpuTexture>;
	var view:Null<GpuTextureView>;
	var binding:Null<GpuBindGroup>;
	var disposed = false;

	function new(renderer:Offscreen, page:Element) {
		var pages = ashui.css.Css.query(page.tree, page.node.id, ".rayde-tab-page");
		if (pages.length == 0)
			throw "Tab page is not mounted";
		var node = new Node(pages[0]);
		var box = page.tree.getBounds(node);
		if (box == null || box.width <= 0 || box.height <= 0)
			throw "Tab page has no layout";
		var scale = Math.min(1, Math.min(320 / box.width, 220 / box.height));
		width = Std.int(Math.max(1, Math.round(box.width * scale)));
		height = Std.int(Math.max(1, Math.round(box.height * scale)));
		texture = renderer.createTexture(width, height);
		view = texture.createView(new GpuTextureViewDescriptor());
		try {
			var list = new DisplayList();
			list.update(page.tree, node, scale);
			var background = ashui.theme.ThemeState.get().color(Surface);
			// Runs after layout, before the window's draw; reuse its device and atlases without a readback or another renderer.
			@:privateAccess renderer.renderer.draw(list, view, Math.ceil(box.width), Math.ceil(box.height), background.r, background.g, background.b, 1,
				width, height);
		} catch (error:Dynamic) {
			dispose();
			throw error;
		}
	}

	public static function capture(page:Element):Null<EditorTabSnapshot> {
		var renderer:Offscreen = null;
		#if ashui_window
		var app = ashui.app.WindowedApp.current;
		if (app != null && app.tree == page.tree)
			renderer = app.offscreen;
		else
			for (window in ashui.app.WindowedApp.windows())
				if (window.tree == page.tree) {
					renderer = window.offscreen;
					break;
				}
		#else
		renderer = ashui.core.render.Snapshot.renderer();
		#end
		return renderer == null ? null : new EditorTabSnapshot(renderer, page);
	}

	public function paint(frame:CanvasFrame):Void {
		if (disposed)
			return;
		var pass = frame.bind(SceneShader.WGSL);
		if (binding == null) {
			var bindings = new GpuBindings();
			bindings.texture(view);
			bindings.sampler(frame.imageSampler);
			binding = frame.device.bindGroup(pass.pipeline, SceneShader.TEXTURE_canvasLayer_GROUP, bindings);
			bindings.destroy();
		}
		frame.encoder.renderSetBindGroup(SceneShader.TEXTURE_canvasLayer_GROUP, binding);
		frame.encoder.renderDrawRange(6, 1, 0, frame.record);
	}

	public function dispose():Void {
		if (disposed)
			return;
		disposed = true;
		if (binding != null)
			binding.destroy();
		if (view != null)
			view.destroy();
		if (texture != null)
			texture.destroy();
		binding = null;
		view = null;
		texture = null;
	}
}
