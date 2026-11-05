import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import rayde.lang.CompilerServer;
import rayde.settings.WorkspaceTrust;
import rayde.settings.Store;
import rayde.ui.WorkspaceWindow;
import rayde.workspace.Fs;
import rayde.workspace.PageHost;

private class GuardedProject extends rayde.workspace.LocalWorkspace {
	public var approved = false;
	public var reads = 0;
	public var delay = false;
	final project:String;
	public function new(project:String) { super(); this.project = project; }
	override public function getContent(path:String):String {
		if (rayde.files.FileOps.inside(project, path)) {
			if (!approved) throw "Read project configuration before consent: " + path;
			reads++;
			if (delay) { delay = false; Sys.sleep(.4); }
		}
		return super.getContent(path);
	}
}

@:access(rayde.settings.WorkspaceTrust)
@:access(rayde.workspace.PageHost)
@:access(rayde.workspace.session.SessionClient)
@:access(rayde.ui.Workbench)
@:access(rayde.ui.WorkspaceWindow)
@:access(rayde.ui.workbench.ProjectPart)
@:access(rayde.ui.workbench.ExplorerPart)
@:access(rayde.ui.workbench.ExtensionsPart)
@:access(rayde.ui.workbench.LanguagesPart)
class WorkspaceTrustChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	public static function main():Void {
		run();
		for (dark in [true, false]) for (width in [680, 1280]) window(dark, width);
		Sys.println("workspace trust: private approvals, canonical roots, remote isolation, template exemption, inert startup, cancellation, async activation and dialog layout passed");
	}
	public static function run():Void identities();

	static function identities():Void {
		var original = Fs.current, previousSession = PageHost.session, previousBridge = PageHost.bridge, previousStorage = PageHost.storage;
		var memory = new rayde.workspace.MemoryWorkspace();
		Fs.current = memory; PageHost.session = null; PageHost.bridge = null; PageHost.storage = null;
		try {
			for (path in ["/user", "/other-user", "/projects/one", "/projects/two", "/workspace/project", "/replacement/project", "/home/web"]) memory.createDirectory(path);
			for (path in ["/projects/one", "/projects/two", "/workspace/project", "/replacement/project"]) memory.saveContent(path + "/build.hxml", "-main Main\n");
			var entry = "/projects/one/build.hxml";
			Store.save("/projects/one", "workspaceTrust", {version:1, approved:[WorkspaceTrust.identity(entry)]});
			check(!WorkspaceTrust.trusted(entry, "/user"), "Project settings granted their own trust");
			Store.save("/user", "appearance", {scheme:"light"});
			WorkspaceTrust.remember(entry, "/user");
			check(WorkspaceTrust.trusted("/projects/one/./build.hxml", "/user") && WorkspaceTrust.trusted("/projects/one/", "/user"), "Folder and project entries lost canonical approval");
			check(!WorkspaceTrust.trusted(entry, "/other-user") && !WorkspaceTrust.trusted("/projects/two", "/user"), "Trust crossed users or sibling folders");
			check(Store.section("/user", "appearance").scheme == "light", "Approval overwrote other settings");
			var relativeHome = false;
			try WorkspaceTrust.remember(entry, ".") catch (_:Dynamic) relativeHome = true;
			check(relativeHome && !WorkspaceTrust.trusted(entry, "."), "Missing private user storage fell back to a project directory");
			check(WorkspaceTrust.root("/") == "/", "Filesystem root became an empty trust identity");
			var session = Type.createEmptyInstance(rayde.workspace.session.SessionClient);
			session.root = "/workspace/project"; session.storageKey = "first-session"; session.workspaceId = [for (_ in 0...43) "a"].join("");
			PageHost.session = session; PageHost.bridge = session; PageHost.storage = memory;
			WorkspaceTrust.rememberCloud(session.workspaceId, "build.hxml", "/home/web");
			check(WorkspaceTrust.trusted("/workspace/project/build.hxml", "/home/web"), "A newly scaffolded cloud template prompted again");
			session.workspaceId = [for (_ in 0...43) "b"].join("");
			check(!WorkspaceTrust.trusted("/workspace/project/build.hxml", "/home/web"), "Different remote workspaces shared their guest mount's trust");
			session.workspaceId = [for (_ in 0...43) "a"].join(""); session.root = "/replacement/project";
			check(WorkspaceTrust.trusted("/replacement/project/build.hxml", "/home/web"), "A restored cloud guest lost its logical workspace approval");
			session.workspaceId = null;
			WorkspaceTrust.remember("/replacement/project/build.hxml", "/home/web");
			session.storageKey = "different-session";
			check(!WorkspaceTrust.trusted("/replacement/project/build.hxml", "/home/web"), "Direct sessions reused another endpoint's approval");
			session.demo = true;
			check(WorkspaceTrust.trusted("/replacement/project/build.hxml", "/home/web"), "The built-in demo asked for redundant approval");
		} catch (error:Dynamic) {
			Fs.current = original; PageHost.session = previousSession; PageHost.bridge = previousBridge; PageHost.storage = previousStorage; throw error;
		}
		Fs.current = original; PageHost.session = previousSession; PageHost.bridge = previousBridge; PageHost.storage = previousStorage;
	}

	static function window(dark:Bool, width:Int):Void {
		var root = Sys.getCwd() + "bin/workspace-trust-" + Std.random(0x3fffffff), home = root + "/home", project = root + "/an-existing-project-with-a-long-folder-name";
		for (path in [home, project, project + "/src", root + "/empty-extensions"]) sys.FileSystem.createDirectory(path);
		var entry = project + "/build.hxml";
		sys.io.File.saveContent(entry, "-cp src\n-main Main\n--hl bin/main.hl\n");
		sys.io.File.saveContent(project + "/src/Main.hx", "class Main { static function main() {} }\n");
		var original = Fs.current, previousHome = Sys.getEnv("HOME"), previousExtensions = Sys.getEnv("RAYDE_EXTENSIONS");
		Sys.putEnv("HOME", home); Sys.putEnv("RAYDE_EXTENSIONS", root + "/empty-extensions");
		var guarded = new GuardedProject(project); Fs.current = guarded;
		Store.save(home, "appearance", {scheme:dark ? "dark" : "light"});
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light); rayde.ui.Style.use();
		var tree = new LayoutTree(), server = new CompilerServer(), stop:Void->Void = null;
		var initial = WorkspaceWindow.prepare(server, entry);
		check(initial.empty == true && initial.pendingTrust == entry && guarded.reads == 0, "Startup parsed an untrusted project before showing its prompt");
		for (file in ["project.cbproj", "extension.rayext", "theme.raytheme", "haxelib.json", "rayzor.toml"]) {
			var path = project + "/" + file;
			sys.io.File.saveContent(path, "invalid until approved");
			check(WorkspaceWindow.prepare(server, path).pendingTrust == path && guarded.reads == 0, "A project descriptor bypassed the trust gate: " + file);
		}
		var host = Owner.root(tree, cleanup -> { stop = cleanup; return new WorkspaceWindow({initial:initial, server:server}); });
		function settle(frames = 5):Void for (_ in 0...frames) { ashui.core.render.Offscreen.advance(.03); Css.setViewport(width, 760); Css.update(); tree.flush(); tree.computeLayout(host.node, width, 760); }
		function nodes(selector:String) return Css.query(tree, host.node.id, selector);
		function box(selector:String) { var found = nodes(selector); check(found.length == 1, "Missing " + selector); return tree.getScrolledBounds(new ashui.layout.Node(found[0])); }
		function click(selector:String):Void { var b = box(selector); ashui.input.Pointer.move(tree, b.x + b.width / 2, b.y + b.height / 2); ashui.input.Pointer.press(tree); ashui.input.Pointer.release(tree); settle(); }
		function until(done:Void->Bool):Void { var end = haxe.Timer.stamp() + 8; while (!done() && haxe.Timer.stamp() < end) { settle(); Sys.sleep(.005); } check(done(), "Workspace activation did not complete: " + host.approvalError.get()); }
		try {
			settle(); var fresh = host.bench, dialog = box("#rayde-workspace-trust-dialog");
			check(dialog.x >= 0 && dialog.x + dialog.width <= width + 1 && dialog.y >= 0 && dialog.y + dialog.height <= 761, "Trust dialog escaped its viewport");
			check(guarded.reads == 0 && fresh.props.empty == true && !host.started && !server.running() && fresh.extensionsPart.extensionManager.extensions.length == 0 && !fresh.languagesPart.languageServers.busy() && !fresh.explorerPart.fileIndex.busy(), "Untrusted startup activated workspace services");
			for (selector in ["#rayde-workspace-trust-path", "#rayde-workspace-trust-cancel", "#rayde-workspace-trust-accept"]) { var b = box(selector); check(b.x >= dialog.x && b.x + b.width <= dialog.x + dialog.width + 1, "Trust content escaped horizontally: " + selector); }
			ashui.core.render.Snapshot.capture('workspace-trust-${dark ? "dark" : "light"}-$width', tree, host.node, width, 760, ashui.theme.ThemeState.get().color(Background).rgb());
			click("#rayde-workspace-trust-cancel");
			check(host.bench == fresh && nodes("#rayde-workspace-trust-dialog").length == 0 && guarded.reads == 0 && !WorkspaceTrust.trusted(entry), "Cancel opened or approved the project");
			host.open(entry); settle(); guarded.approved = true; guarded.delay = true;
			click("#rayde-workspace-trust-accept");
			check(host.approving.get() && host.bench == fresh, "Project IO blocked the trust dialog's opening feedback");
			until(() -> host.bench != fresh);
			check(fresh.gone && WorkspaceTrust.trusted(entry) && guarded.reads > 0 && host.bench.display().project.file == entry && nodes("#rayde-workspace-trust-dialog").length == 0, "Consent did not activate and remember the project");
			check(WorkspaceWindow.prepare(server, entry).pendingTrust == null, "A reopened approved project prompted again");
			var template = rayde.project.ProjectFile.create(root, "new-template", "hxml");
			host.bench.projectPart.createdProject(template); settle();
			check(WorkspaceTrust.trusted(template) && host.bench.display().project.file == template && nodes("#rayde-workspace-trust-dialog").length == 0, "New Project requested redundant author trust");
		} catch (error:Dynamic) {
			stop(); tree.dispose(); server.stop(); Fs.current = original; Sys.putEnv("HOME", previousHome); Sys.putEnv("RAYDE_EXTENSIONS", previousExtensions); throw error;
		}
		stop(); tree.dispose(); server.stop(); Fs.current = original; Sys.putEnv("HOME", previousHome); Sys.putEnv("RAYDE_EXTENSIONS", previousExtensions);
	}
}
