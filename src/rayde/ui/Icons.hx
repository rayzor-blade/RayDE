package rayde.ui;

/** RayDE's icons as typed SVG documents, such as `Icons.PLAY_LINE`: ashui's Remix set, RayDE's own in `icons`, and its wordmarks in `assets`. */
@:build(ashui.svg.IconSet.build(["ashui/icons/remix", "rayde/ui/icons", "rayde/ui/assets"]))
class Icons {
	/** The wordmark for a dark page, white, or for a light one, black; the DE is orange on both. */
	public static inline function wordmark(dark:Bool):ashui.svg.SvgDocument
		return dark ? RAYDE_DARK_TRANSPARENT_FINAL : RAYDE_LIGHT_TRANSPARENT_FINAL;
}
