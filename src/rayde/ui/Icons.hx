package rayde.ui;

/** RayDE's icons as typed SVG documents, such as `Icons.PLAY_LINE`: ashui's Remix set, RayDE's own in `icons`, and its wordmarks in `assets`. */
@:build(ashui.svg.IconSet.build(["ashui/icons/remix", "rayde/ui/icons", "rayde/ui/assets"]))
class Icons {
	/** The current workspace's folder: cloud-backed when a browser is connected to a session. */
	public static function workspaceFolder(opened = false):ashui.svg.SvgDocument {
		#if (wasm || rayde_page)
		if (rayde.workspace.PageHost.session != null) return FOLDER_CLOUD_LINE;
		#end
		return opened ? FOLDER_OPEN_LINE : FOLDER_3_LINE;
	}

	/** The wordmark for a dark page, white, or for a light one, black; the DE is orange on both. */
	public static inline function wordmark(dark:Bool):ashui.svg.SvgDocument
		return dark ? RAYDE_DARK_TRANSPARENT_FINAL : RAYDE_LIGHT_TRANSPARENT_FINAL;
}
