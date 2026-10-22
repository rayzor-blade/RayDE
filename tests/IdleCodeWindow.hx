import ashui.app.WindowedApp;
import rayde.ui.ProjectWindows;
import rayde.ui.WorkspaceWindow;

@:access(rayde.ui.ProjectWindows)
@:access(rayde.ui.Workbench)
class IdleCodeWindow {
	static function main() {
		rayde.ui.Style.use();
		var root = Sys.args()[0], files = Sys.args().slice(1);
		var entry = ProjectWindows.prepare(root);
		var host:WorkspaceWindow = null, focused = false;
		entry.config.data.onFrame = (frame, seconds) -> {
			if (frame == 1) for (file in files) host.bench.openFile(file);
			if (!focused && files.length > 0) {
				var editor = host.bench.editorFor(files[files.length - 1]);
				if (editor != null) { editor.focus(); focused = true; }
			}
		};
		WindowedApp.run(entry.config, () -> { host = cast entry.build(); return host; });
	}
}
