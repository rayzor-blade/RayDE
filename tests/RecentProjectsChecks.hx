import rayde.settings.RecentProjects;
import rayde.settings.Store;

class RecentProjectsChecks {
	public static function run():Void {
		var root = Sys.getCwd() + "bin/check-recent-projects", home = root + "/home", other = root + "/other";
		for (dir in [root, home, other]) sys.FileSystem.createDirectory(dir);
		Store.save(home, "recentProjects", {paths:[]});
		Store.save(other, "recentProjects", {paths:[]});
		Store.save(home, "appearance", {theme:"test"});
		var first = root + "/space λ.hxml", second = root + "/extension.rayext";
		for (file in [first, second]) sys.io.File.saveContent(file, "");
		RecentProjects.remember(first, home); RecentProjects.remember(second, home); RecentProjects.remember(first, home);
		if (RecentProjects.paths(home).join(",") != first + "," + second) throw "Recent projects lost recency, deduplication, spaces or Unicode";
		if (Store.section(home, "appearance").theme != "test" || RecentProjects.paths(other).length != 0) throw "Project history overwrote settings or crossed users";
		Store.save(home, "recentProjects", {paths:([first, root, "relative.hxml", root + "/missing.hxml", null, 12, first, second]:Array<Dynamic>)});
		if (RecentProjects.paths(home).join(",") != first + "," + root + "," + second) throw "Recent workspaces lost folders or accepted malformed or missing entries";
		RecentProjects.remember(root, home);
		if (RecentProjects.paths(home)[0] != root) throw "Folder workspaces do not retain recency";
		for (i in 0...25) {
			var file = root + '/project$i.hxml'; sys.io.File.saveContent(file, ""); RecentProjects.remember(file, home);
		}
		var saved = RecentProjects.paths(home);
		if (saved.length != 20 || saved[0] != root + "/project24.hxml" || saved[19] != root + "/project5.hxml") throw "Recent project history is not bounded";
		sys.FileSystem.deleteFile(saved[0]);
		if (RecentProjects.paths(home).indexOf(saved[0]) >= 0) throw "Deleted project entry points remain in the picker";
		Sys.println("recent projects: persistence, recency, deduplication, missing paths, Unicode, user isolation and bounded history");
	}
}
