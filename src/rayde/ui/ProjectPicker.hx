package rayde.ui;

import rayde.workspace.Fs;

typedef ProjectPickRequest = {mode:String, ?kind:String, ?name:String, ?selected:String, ?scaffold:rayde.project.ProjectTemplates.ProjectScaffold};

/** Native path selection, invoked by a worker only after an explicit Welcome action. */
class ProjectPicker {
	public static function choose(request:ProjectPickRequest, cancelled:Void->Bool):Null<String> {
		if (cancelled()) return null;
		var folder = request.mode != "project", title = folder ? request.mode == "new" || request.mode == "parent" ? "Choose a parent folder" : "Open Folder Workspace" : "Open Project";
		var chosen = request.selected != null ? request.selected : switch Sys.systemName() {
			case "Mac": run("/usr/bin/osascript", ["-e", 'on run argv\ntry\nreturn POSIX path of (choose ${folder ? "folder" : "file"} with prompt (item 1 of argv)${folder ? "" : ' of type {"hxml", "json", "toml", "cbproj", "rayext", "raytheme"}'})\non error number -128\nreturn ""\nend try\nend run', "--", title], cancelled);
			case "Windows":
				var script = "[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); Add-Type -AssemblyName System.Windows.Forms; " + (folder
					? " $d = New-Object System.Windows.Forms.FolderBrowserDialog; $d.Description = '" + title + "';"
					: " $d = New-Object System.Windows.Forms.OpenFileDialog; $d.Title = 'Open Project'; $d.Filter = 'RayDE projects|*.hxml;*.json;*.toml;*.cbproj;*.rayext;*.raytheme';")
					+ " if ($d.ShowDialog() -eq 'OK') { " + (folder ? "$d.SelectedPath" : "$d.FileName") + " }";
				run("powershell", ["-STA", "-NoProfile", "-Command", script], cancelled);
			case _:
				if (available("zenity")) run("zenity", ["--file-selection", "--title=" + title].concat(folder ? ["--directory"] : []), cancelled);
				else if (available("kdialog")) run("kdialog", folder ? ["--getexistingdirectory", ".", "--title", title] : ["--getopenfilename", ".", "*.hxml *.json *.toml *.cbproj *.rayext *.raytheme", "--title", title], cancelled);
				else throw "Install zenity or kdialog to choose a workspace";
		};
		if (chosen == null || chosen == "" || cancelled()) return null;
		if (request.mode == "new") return rayde.project.ProjectFile.create(chosen, request.name, request.kind, request.scaffold);
		if (folder && !Fs.isDirectory(chosen)) throw "Choose a folder workspace";
		return chosen;
	}

	static function available(command:String):Bool {
		var path = Sys.getEnv("PATH");
		return path != null && Lambda.exists(path.split(":"), directory -> Fs.exists(haxe.io.Path.join([directory, command])));
	}

	static function run(command:String, args:Array<String>, cancelled:Void->Bool):Null<String> {
		var picker = new sys.io.Process(command, args);
		var status:Null<Int>;
		while ((status = picker.exitCode(false)) == null) {
			if (cancelled()) { picker.kill(); picker.close(); return null; }
			Sys.sleep(.05);
		}
		var chosen = picker.stdout.readAll().toString(), error = picker.stderr.readAll().toString();
		picker.close();
		if (status == 1 && (command == "zenity" || command == "kdialog")) return null;
		if (status != 0) throw error == "" ? "Cannot open the workspace picker" : error;
		if (StringTools.endsWith(chosen, "\n")) chosen = chosen.substr(0, chosen.length - 1);
		if (StringTools.endsWith(chosen, "\r")) chosen = chosen.substr(0, chosen.length - 1);
		return chosen == "" ? null : chosen;
	}
}
