package rayde.ui;

import ashui.components.Icon;
import ashui.layout.Element;

/** The pieces every section of the Settings page is made of: the scrolling column, the heading, a card around a group of settings, and one setting with its control. */
class SettingsParts {
	/** The column a section is laid out in, which scrolls and sits in the middle of the page. */
	public static function page(id:String, body:Element):Element
		return <div id={id} class="rayde-settings flex flex-1 min-h-0 justify-center overflow-auto">
			<div class="flex flex-col gap-6 px-8 py-8" width={780}>
				${body}
				<div class="shrink-0" height={40}/>
			</div>
		</div>;

	public static function header(icon:ashui.svg.SvgDocument, title:String, subtitle:String):Element
		return <div class="flex items-center gap-4">
			<div class="rayde-tile flex items-center justify-center shrink-0" width={44} height={44}><icon document={icon} class="size-5"/></div>
			<div class="flex flex-col gap-1">
				<text class="text-2xl font-semibold tracking-tighter">${title}</text>
				<text class="text-sm text-text-secondary">${subtitle}</text>
			</div>
		</div>;

	public static function card(id:String, title:String, description:String, content:Array<Element>):Element
		return <div id={id} class="rayde-setting-card flex flex-col gap-4 p-5">
			<div class="flex flex-col gap-1">
				<text class="text-sm font-semibold">${title}</text>
				<text class="text-xs text-text-tertiary">${description}</text>
			</div>
			<div class="flex flex-col gap-3">{content}</div>
		</div>;

	/** A setting: what it is, a line on it, and its control at the end. */
	public static function field(label:String, hint:String, control:Element):Element
		return <div class="flex items-center justify-between gap-6">
			<div class="flex flex-col gap-1 min-w-0">
				<text class="text-sm">${label}</text>
				<text class="text-xs text-text-tertiary">${hint}</text>
			</div>
			<div class="shrink-0">${control}</div>
		</div>;
}
