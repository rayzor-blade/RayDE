package rayde.ui;

import rayde.settings.RecentProjects;
import rayde.project.ProjectFile;

/** The macOS startup picker opens existing projects or creates a new project from a template. */
class ProjectPicker {
	static final SCRIPT = '
on run argv
    set labels to {}
    set paths to {}
    repeat with i from 1 to count argv by 2
        set end of paths to item i of argv
        set end of labels to item (i + 1) of argv
    end repeat
    set browseLabel to "Open Existing Project…"
    set createLabel to "New Project…"
    set end of labels to browseLabel
    set end of labels to createLabel
    try
        set picked to choose from list labels with title "RayDE" with prompt "Open a recent project, open an existing project, or create a new one." default items {item 1 of labels} OK button name "Continue" cancel button name "Cancel"
        if picked is false then return ""
        set selectedLabel to item 1 of picked
        if selectedLabel is createLabel then
            set templates to {"Haxe application (build.hxml)", "Haxe library (haxelib.json)", "Rayzor application (rayzor.toml)"}
            set template to choose from list templates with title "New Project" with prompt "Choose the project type." default items {item 1 of templates}
            if template is false then return ""
            set kind to "hxml"
            if item 1 of template is item 2 of templates then set kind to "haxelib"
            if item 1 of template is item 3 of templates then set kind to "rayzor"
            set parentFolder to POSIX path of (choose folder with prompt "Choose the parent folder for the new project")
            set projectName to text returned of (display dialog "Project name (a new folder will be created):" default answer "my-project" with title "New Project" buttons {"Cancel", "Create"} default button "Create")
            return "new" & linefeed & kind & linefeed & projectName & linefeed & parentFolder
        else if selectedLabel is not browseLabel then
            repeat with i from 1 to count paths
                if item i of labels is selectedLabel then return item i of paths
            end repeat
        end if
        return POSIX path of (choose file with prompt "Open an .hxml, haxelib.json or rayzor.toml project (or a RayDE extension/theme)" of type {"hxml", "json", "toml", "rayext", "raytheme"})
    on error number -128
        return ""
    end try
end run';

	public static function pick():Null<String> {
		while (true) {
			var args = ["-e", SCRIPT, "--"];
			for (file in RecentProjects.paths()) {
				var folder = haxe.io.Path.directory(file);
				args.push(file);
				args.push(haxe.io.Path.withoutDirectory(folder) + " · " + haxe.io.Path.withoutDirectory(file) + " — " + folder);
			}
			var chosen = run(args);
			if (chosen == null || chosen == "") return null;
			try {
				if (StringTools.startsWith(chosen, "new\n")) {
					var fields = chosen.split("\n");
					return ProjectFile.create(fields.slice(3).join("\n"), fields[2], fields[1]);
				}
				if (!rayde.ext.Manifest.isManifest(chosen) && !rayde.theme.ThemeFile.isThemeFile(chosen)) ProjectFile.read(chosen);
				return chosen;
			} catch (error:Dynamic) {
				run(["-e", 'on run argv\n display alert "Cannot open project" message (item 1 of argv) as warning\n return ""\nend run', "--", Std.string(error)]);
			}
		}
	}

	static function run(args:Array<String>):Null<String> {
		var picker = new sys.io.Process("/usr/bin/osascript", args);
		var chosen = picker.stdout.readAll().toString(), error = picker.stderr.readAll().toString(), status = picker.exitCode();
		picker.close();
		if (status != 0 && error != "") Sys.stderr().writeString("Project picker: " + error);
		if (StringTools.endsWith(chosen, "\n")) chosen = chosen.substr(0, chosen.length - 1);
		return status == 0 ? chosen : null;
	}
}
