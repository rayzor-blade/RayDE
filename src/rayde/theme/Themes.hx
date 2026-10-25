package rayde.theme;

import rayde.workspace.Fs;

/** A theme found on disk: its file, and where it was found. */
typedef InstalledTheme = {file:ThemeFile, scope:String, path:String};

/**
 * The themes installed beyond RayDE's own: a `.raytheme` file, loose or in a folder of its own, under `.rayde/themes`
 * in the workspace or in the user's. `RAYDE_THEMES=<folder>` names the user's folder instead of `~/.rayde/themes`;
 * it is safe either way. A theme is installed by putting it there, which `install` does from a file or a folder.
 */
class Themes {
	static final local = new ashui.core.UiContext.Local(() -> new Array<InstalledTheme>());
	static var found(get, set):Array<InstalledTheme>;
	static function get_found() return local.value;
	static function set_found(value:Array<InstalledTheme>) return local.value = value;

	/** The folder a theme is installed into, for every project. */
	public static function userDir():Null<String> {
		var own = Sys.getEnv("RAYDE_THEMES");
		if (own != null && own != "")
			return own;
		var home = Sys.getEnv("HOME");
		if (home == null || home == "")
			home = Sys.getEnv("USERPROFILE");
		return home == null || home == "" ? null : haxe.io.Path.join([home, ".rayde", "themes"]);
	}

	/** Reads the themes there are, the workspace's before the user's, and keeps them for `find`. */
	public static function scan(root:String):Array<InstalledTheme> {
		var out:Array<InstalledTheme> = [];
		look(haxe.io.Path.join([root, ".rayde", "themes"]), "Workspace", out);
		var user = userDir();
		if (user != null)
			look(user, "User", out);
		found = out;
		return out;
	}

	/** The themes read by the last `scan`. */
	public static function installed():Array<InstalledTheme>
		return found;

	public static function find(id:String):Null<InstalledTheme>
		return Lambda.find(found, t -> t.file.id == id);

	static function look(dir:String, scope:String, out:Array<InstalledTheme>):Void {
		if (!Fs.exists(dir) || !Fs.isDirectory(dir))
			return;
		var names = Fs.readDirectory(dir);
		names.sort(Reflect.compare);
		var add = (path:String) -> {
			var t = ThemeFile.read(path);
			if (!Lambda.exists(out, o -> o.file.id == t.id))
				out.push({file: t, scope: scope, path: path});
		};
		for (name in names) {
			var path = haxe.io.Path.join([dir, name]);
			if (name.charAt(0) == ".")
				continue;
			if (Fs.isDirectory(path)) {
				var files = [for (f in Fs.readDirectory(path)) if (ThemeFile.isThemeFile(f)) f];
				files.sort(Reflect.compare);
				if (files.length > 0)
					add(haxe.io.Path.join([path, files[0]]));
			} else if (ThemeFile.isThemeFile(name))
				add(path);
		}
	}

	/**
	 * Installs a theme into the user's folder from a `.raytheme` file, or from a folder that holds one (the folder is
	 * copied whole, its stylesheets and fonts with it). The theme replaces one installed with the same id. A theme that has
	 * problems is not installed; the sentences say why. The theme as installed, or null.
	 */
	public static function install(source:String, problems:Array<String>):Null<InstalledTheme> {
		var user = userDir();
		if (user == null) {
			problems.push("There is no home folder to install into; set RAYDE_THEMES to a folder.");
			return null;
		}
		if (!Fs.exists(source)) {
			problems.push('Nothing at $source.');
			return null;
		}
		var file = source, folder = false;
		if (Fs.isDirectory(source)) {
			var files = [for (f in Fs.readDirectory(source)) if (ThemeFile.isThemeFile(f)) f];
			files.sort(Reflect.compare);
			if (files.length == 0) {
				problems.push('No ${ThemeFile.EXTENSION} file in $source.');
				return null;
			}
			file = haxe.io.Path.join([source, files[0]]);
			folder = true;
		} else if (!ThemeFile.isThemeFile(source)) {
			problems.push('A theme file ends in ${ThemeFile.EXTENSION}.');
			return null;
		}
		var theme = ThemeFile.read(file);
		if (theme.problems.length > 0) {
			for (p in theme.problems)
				problems.push(p);
			return null;
		}
		var target = haxe.io.Path.join([user, theme.id]);
		if (Fs.exists(target))
			deleteTree(target);
		ensure(user);
		copyTree(folder ? source : haxe.io.Path.directory(file), target, folder ? null : file, theme);
		return {file: ThemeFile.read(haxe.io.Path.join([target, haxe.io.Path.withoutDirectory(file)])), scope: "User", path: target};
	}

	/** Takes an installed theme away: the file or folder it was in, if it is the user's. */
	public static function remove(id:String):Bool {
		var t = find(id);
		var user = userDir();
		if (t == null || t.scope != "User" || user == null)
			return false;
		var folder = haxe.io.Path.directory(t.path);
		if (haxe.io.Path.normalize(folder) == haxe.io.Path.normalize(user))
			Fs.deleteFile(t.path);
		else
			deleteTree(folder);
		found = found.filter(x -> x.file.id != id);
		return true;
	}

	static function copyTree(from:String, to:String, only:Null<String>, theme:ThemeFile):Void {
		ensure(to);
		if (only != null) {
			// A loose file brings only itself, the stylesheets it names and its fonts.
			Fs.copy(only, haxe.io.Path.join([to, haxe.io.Path.withoutDirectory(only)]));
			var named = [for (s in theme.css) if (s.file != null) s.file];
			for (f in theme.fonts)
				for (name in f.files)
					named.push(name);
			for (name in named) {
				var target = haxe.io.Path.join([to, name]);
				ensure(haxe.io.Path.directory(target));
				Fs.copy(haxe.io.Path.join([from, name]), target);
			}
			return;
		}
		for (name in Fs.readDirectory(from)) {
			if (name.charAt(0) == ".")
				continue;
			var source = haxe.io.Path.join([from, name]), target = haxe.io.Path.join([to, name]);
			if (Fs.isDirectory(source))
				copyTree(source, target, null, theme);
			else
				Fs.copy(source, target);
		}
	}

	/** Makes `dir` and the folders above it that are missing. */
	public static function ensure(dir:String):Void {
		if (dir == "" || Fs.exists(dir))
			return;
		ensure(haxe.io.Path.directory(dir));
		Fs.createDirectory(dir);
	}

	static function deleteTree(path:String):Void {
		if (Fs.isDirectory(path)) {
			for (entry in Fs.readDirectory(path))
				deleteTree(haxe.io.Path.join([path, entry]));
			Fs.deleteDirectory(path);
		} else
			Fs.deleteFile(path);
	}
}
