package rayde;

/**
 * What RayDE presents itself as, and what its keys are.
 * The window and the workspace (window controls, menus, wording, runtime) present as a Mac in a page, whatever the visitor runs.
 * Shortcuts follow the visitor's own keyboard: the page tells the program its platform in RAYDE_VISITOR, and Mac is assumed when it does not.
 */
class Platform {
	public static inline function isMac():Bool {
		#if (wasm || rayde_page)
		return true;
		#else
		return Sys.systemName() == "Mac";
		#end
	}

	/** Whether the operating system draws the window's frame and edge. A page draws its own window, so it does not. */
	public static inline function systemFrame():Bool {
		#if (wasm || rayde_page)
		return false;
		#else
		return true;
		#end
	}

	/** Whether RayDE is the page's own app (an installed web app, or `RAYDE_STANDALONE=1`) and not a part of another page such as the landing page. */
	public static function standalone():Bool {
		#if (wasm || rayde_page)
		return Sys.getEnv("RAYDE_STANDALONE") == "1";
		#else
		return false;
		#end
	}

	/** Whether shortcuts are written and bound with ⌘, as a Mac's are. */
	public static function shortcutsMac():Bool {
		#if (wasm || rayde_page)
		var visitor = Sys.getEnv("RAYDE_VISITOR");
		return visitor == null || visitor == "" || visitor == "Mac";
		#else
		return Sys.systemName() == "Mac";
		#end
	}
}
