package rayde.ui;

import rayde.settings.RecentProjects;

/** The macOS startup picker opens remembered entry points, with a file browser for new projects. */
class ProjectPicker {
	static final SCRIPT = '
on run argv
    set labels to {}
    set paths to {}
    repeat with i from 1 to count argv by 2
        set end of paths to item i of argv
        set end of labels to item (i + 1) of argv
    end repeat
    set browseLabel to "Browse for another project…"
    if (count labels) > 0 then
        set end of labels to browseLabel
        set picked to choose from list labels with title "RayDE" with prompt "Open a recent project, or browse for a new one." default items {item 1 of labels} OK button name "Open" cancel button name "Cancel"
        if picked is false then return ""
        set selectedLabel to item 1 of picked
        if selectedLabel is not browseLabel then
            repeat with i from 1 to count paths
                if item i of labels is selectedLabel then return item i of paths
            end repeat
        end if
    end if
    try
        return POSIX path of (choose file with prompt "Open a project: .hxml, .rayext or .raytheme" of type {"hxml", "rayext", "raytheme"})
    on error number -128
        return ""
    end try
end run';

	public static function pick():Null<String> {
		var args = ["-e", SCRIPT, "--"];
		for (file in RecentProjects.paths()) {
			var folder = haxe.io.Path.directory(file);
			args.push(file);
			args.push(haxe.io.Path.withoutDirectory(folder) + " · " + haxe.io.Path.withoutDirectory(file) + " — " + folder);
		}
		var picker = new sys.io.Process("/usr/bin/osascript", args);
		var chosen = picker.stdout.readAll().toString(), error = picker.stderr.readAll().toString(), status = picker.exitCode();
		picker.close();
		if (status != 0 && error != "") Sys.stderr().writeString("Project picker: " + error);
		chosen = StringTools.rtrim(chosen);
		return status == 0 && chosen != "" ? chosen : null;
	}
}
