package rayde.ui;

import rayde.ext.Manifest;
import rayde.ext.Manifest.ViewTool;

/**
 * The icons of extension views: the SVG file an extension's config names, read once, or one of RayDE's own by name; and
 * RayDE's puzzle piece when it names none or the file is no SVG.
 */
class ViewIcons {
	static final read = new Map<String, Null<ashui.svg.SvgDocument>>();

	/** The icons an extension can ask for by name, as `refresh` or `refresh-line`. */
	static final NAMED:Map<String, ashui.svg.SvgDocument> = [
		"add" => Icons.ADD_LINE,
		"subtract" => Icons.SUBTRACT_LINE,
		"refresh" => Icons.REFRESH_LINE,
		"search" => Icons.SEARCH_LINE,
		"settings" => Icons.SETTINGS_3_LINE,
		"play" => Icons.PLAY_LINE,
		"pause" => Icons.PAUSE_LINE,
		"stop" => Icons.STOP_LINE,
		"delete" => Icons.DELETE_BIN_LINE,
		"close" => Icons.CLOSE_LINE,
		"save" => Icons.SAVE_3_LINE,
		"edit" => Icons.EDIT_LINE,
		"pencil" => Icons.PENCIL_LINE,
		"copy" => Icons.FILE_COPY_LINE,
		"filter" => Icons.FILTER_LINE,
		"download" => Icons.DOWNLOAD_LINE,
		"upload" => Icons.UPLOAD_LINE,
		"check" => Icons.CHECK_LINE,
		"info" => Icons.INFORMATION_LINE,
		"bug" => Icons.BUG_LINE,
		"more" => Icons.MORE_LINE,
		"external" => Icons.EXTERNAL_LINK_LINE,
		"up" => Icons.ARROW_UP_LINE,
		"down" => Icons.ARROW_DOWN_LINE,
		"left" => Icons.ARROW_LEFT_LINE,
		"right" => Icons.ARROW_RIGHT_LINE,
		"folder" => Icons.FOLDER_LINE,
		"new-file" => Icons.FILE_ADD_LINE,
		"new-folder" => Icons.FOLDER_ADD_LINE,
		"link" => Icons.LINK,
		"eye" => Icons.EYE_LINE,
		"eye-off" => Icons.EYE_OFF_LINE,
		"star" => Icons.STAR_LINE,
		"bookmark" => Icons.BOOKMARK_LINE,
		"history" => Icons.HISTORY_LINE,
		"timer" => Icons.TIMER_LINE,
		"list" => Icons.LIST_CHECK,
		"grid" => Icons.LAYOUT_GRID_LINE,
		"menu" => Icons.MENU_LINE,
		"home" => Icons.HOME_LINE,
		"terminal" => Icons.TERMINAL_BOX_LINE,
		"code" => Icons.CODE_LINE,
		"branch" => Icons.GIT_BRANCH_LINE,
		"pin" => Icons.PUSHPIN_LINE,
		"lock" => Icons.LOCK_LINE,
		"cloud" => Icons.CLOUD_LINE,
		"help" => Icons.QUESTION_LINE,
		"warning" => Icons.ALERT_LINE
	];

	/** The names of the icons an extension can ask for. */
	public static function names():Array<String> {
		var out = [for (k in NAMED.keys()) k];
		out.sort(Reflect.compare);
		return out;
	}

	static function file(path:Null<String>):Null<ashui.svg.SvgDocument> {
		if (path == null || !sys.FileSystem.exists(path))
			return null;
		var key = path + "@" + Std.string(sys.FileSystem.stat(path).mtime.getTime());
		if (!read.exists(key))
			read.set(key, try ashui.svg.SvgDocument.parse(sys.io.File.getContent(path)) catch (_:Dynamic) null);
		return read.get(key);
	}

	/** The icon of an extension's view. */
	public static function of(m:Manifest):ashui.svg.SvgDocument {
		var doc = file(m.iconPath());
		return doc == null ? Icons.PUZZLE_LINE : doc;
	}

	/** The icon of a tool in the view's header: its SVG file, or the icon of RayDE's it names. */
	public static function tool(m:Manifest, t:ViewTool):ashui.svg.SvgDocument {
		var icon = named(m, t.icon);
		return icon == null ? Icons.APPS_LINE : icon;
	}

	/** An icon an extension's config wrote: its SVG file, or the icon of RayDE's it names; null when it names none, or none that exists. */
	public static function named(m:Manifest, icon:Null<String>):Null<ashui.svg.SvgDocument> {
		var doc = file(m.iconFile(icon));
		if (doc != null)
			return doc;
		return icon == null ? null : NAMED.get(StringTools.endsWith(icon, "-line") ? icon.substr(0, icon.length - 5) : icon);
	}
}
