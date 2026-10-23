package rayde.ui;

import ashui.components.TreeView;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.run.Haxelib;

using StringTools;

private typedef Dependency = {entry:String, name:String, version:String, paths:Array<String>, error:String};

typedef ExplorerDependenciesProps = {
	root:String, args:Array<String>, folders:Array<{dir:String, label:String}>, onOpen:String->Void,
	onPaths:Array<String>->Void
};

/** Build libraries resolved off the UI thread; source folders create their rows on first expansion. */
class ExplorerDependencies extends Component<ExplorerDependenciesProps> {
	public static function entries(args:Array<String>):Array<String> {
		var out:Array<String> = [];
		for (i in 0...args.length - 1) if (["-lib", "--library", "-L"].indexOf(args[i]) >= 0 && out.indexOf(args[i + 1]) < 0) out.push(args[i + 1]);
		return out;
	}

	function render():Element {
		var rows = Signal.make(([]:Array<Dependency>)), message = Signal.make("Loading dependencies…"), job = new ExplorerJob(props.root);
		var libs = entries(props.args);
		if (libs.length == 0) { message.set(props.folders.length == 0 ? "No dependencies in this build" : ""); props.onPaths([]); }
		else job.run(Haxelib.command(), ["list"], (_, text) -> {
			var installed = Haxelib.parse(text);
			var initial:Array<Dependency> = [for (entry in libs) {
				var split = entry.indexOf(":"), name = split < 0 ? entry : entry.substr(0, split);
				var lib = Lambda.find(installed, l -> l.name == name);
				{entry:entry, name:name, version:split < 0 ? lib == null ? "missing" : lib.version : entry.substr(split + 1), paths:[], error:"Resolving library…"};
			}];
			rows.set(initial); message.set("");
			function resolve(index:Int):Void {
				if (index >= initial.length) return;
				var lib = initial[index];
				job.run(Haxelib.command(), ["path", lib.entry], (code, output) -> {
					var paths = [];
					if (code == 0) for (line in output.split("\n")) {
						var path = line.trim();
						if (path != "" && !path.startsWith("-")) {
							if (!haxe.io.Path.isAbsolute(path)) path = haxe.io.Path.join([props.root, path]);
							if (sys.FileSystem.exists(path) && sys.FileSystem.isDirectory(path) && paths.indexOf(path) < 0) paths.push(path);
						}
					}
					initial[index] = {entry:lib.entry, name:lib.name, version:lib.version, paths:paths, error:paths.length == 0 ? "Library sources unavailable; check Libraries settings" : ""};
					props.onPaths([for (item in initial) for (path in item.paths) path]);
					rows.set(initial.copy()); resolve(index + 1);
				});
			}
			resolve(0);
		});
		return <div id="rayde-dependencies-scroll" class="flex flex-col flex-1 min-h-0 overflow-auto">
			<if {message.get() != ""}><div class="px-3 py-2"><text class="text-xs text-text-secondary">${message.get()}</text></div></if>
			<for {items in [rows.get()]}><tree-view id="rayde-dependencies-tree" onSelect={path -> { if (haxe.io.Path.isAbsolute(path) && sys.FileSystem.exists(path) && !sys.FileSystem.isDirectory(path)) props.onOpen(path); }}>{[for (folder in props.folders) directory(folder.dir, folder.label)].concat([for (lib in items) library(lib)])}</tree-view></for>
		</div>;
	}

	function library(lib:Dependency):Element
		return new TreeItem({id:"rayde-dependency-" + haxe.crypto.Md5.encode(lib.entry) + (lib.paths.length > 0 ? "-ready" : ""),
			value:lib.entry, label:lib.name + (lib.version == "" ? "" : " (" + lib.version + ")"), icon:Icons.ARCHIVE_LINE}, libraryChildren(lib));

	function libraryChildren(lib:Dependency):Array<Element> {
		if (lib.paths.length == 0) return [<tree-item value={"unavailable:" + lib.entry} label={lib.error}/>];
		return [for (path in lib.paths) directory(path, haxe.io.Path.withoutDirectory(haxe.io.Path.removeTrailingSlashes(path)))];
	}

	function directory(path:String, label:String):Element
		return <tree-item id={"rayde-library-" + haxe.crypto.Md5.encode(path)} value={path} label={label} icon={Icons.FOLDER_LINE} load={() -> childrenOf(path)}/>;

	function childrenOf(path:String):Array<Element> {
		var names = try sys.FileSystem.readDirectory(path) catch (_:Dynamic) [];
		names.sort(Reflect.compare);
		return [for (name in names) {
			var full = haxe.io.Path.join([path, name]);
			sys.FileSystem.isDirectory(full) ? directory(full, name) : <tree-item id={"rayde-library-file-" + haxe.crypto.Md5.encode(full)} value={full} label={name} icon={FileIcons.of(full)}/>;
		}];
	}
}
