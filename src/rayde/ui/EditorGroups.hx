package rayde.ui;

import ashui.reactive.Signal;
import rayde.settings.WorkspaceSession.EditorLayoutSession;

class EditorGroup {
	public final id:Int;
	public final files = Signal.make(([] : Array<String>));
	public final active = Signal.make("");

	public function new(id:Int)
		this.id = id;
}

typedef EditorSplit = {direction:String, first:EditorNode, second:EditorNode, ratio:Signal<Float>};

enum EditorNode {
	Group(group:EditorGroup);
	Split(split:EditorSplit);
}

/** A tab has one owner; all groups share the workbench's document and undo stores. */
class EditorGroups {
	public final layout:Signal<EditorNode>;
	public final focused = Signal.make(0);
	public final revision = Signal.make(0);

	final selected:Signal<String>;
	var nextId = 1;

	public function new(selected:Signal<String>) {
		this.selected = selected;
		layout = Signal.make(Group(new EditorGroup(0)));
	}

	function changed():Void
		revision.set(revision.get() + 1);

	public function all():Array<EditorGroup> {
		var result:Array<EditorGroup> = [];
		function visit(node:EditorNode):Void
			switch node {
				case Group(group):
					result.push(group);
				case Split(split):
					visit(split.first);
					visit(split.second);
			}
		visit(layout.get());
		return result;
	}

	public function current():EditorGroup
		return Lambda.find(all(), g -> g.id == focused.get()) ?? all()[0];

	public function owner(file:String):Null<EditorGroup>
		return Lambda.find(all(), g -> g.files.get().indexOf(file) >= 0);

	public function select(group:EditorGroup, ?file:String):Void {
		var moved = focused.get() != group.id || selected.get() != group.active.get();
		if (file != null && group.files.get().indexOf(file) >= 0 && group.active.get() != file) {
			group.active.set(file);
			moved = true;
		}
		if (focused.get() != group.id)
			focused.set(group.id);
		if (selected.get() != group.active.get())
			selected.set(group.active.get());
		if (moved)
			changed();
	}

	/** Adopts opens/closes from file commands and extensions without rebuilding other groups. */
	public function sync(files:Array<String>, front:String):Void {
		var groups = all(),
			lost:Array<Int> = [],
			seen = new Map<String, Bool>(),
			touched = false;
		for (group in groups) {
			var before = group.files.get(), kept:Array<String> = [];
			for (file in before)
				if (files.indexOf(file) >= 0 && !seen.exists(file)) {
					seen.set(file, true);
					kept.push(file);
				}
			if (kept.length != before.length) {
				group.files.set(kept);
				touched = true;
				if (kept.length == 0 && before.length > 0)
					lost.push(group.id);
			}
			if (kept.indexOf(group.active.get()) < 0) {
				var next = kept.length == 0 ? "" : kept[0];
				if (group.active.get() != next)
					group.active.set(next);
			}
		}
		var target = current();
		for (file in files)
			if (!seen.exists(file)) {
				target.files.set(target.files.get().concat([file]));
				seen.set(file, true);
				touched = true;
				if (target.active.get() == "")
					target.active.set(file);
			}
		for (id in lost)
			if (all().length > 1 && Lambda.find(all(), g -> g.id == id).files.get().length == 0) {
				layout.set(remove(layout.get(), id));
				touched = true;
			}
		var frontGroup = owner(front);
		if (frontGroup != null) {
			if (focused.get() != frontGroup.id || frontGroup.active.get() != front)
				touched = true;
			if (focused.get() != frontGroup.id)
				focused.set(frontGroup.id);
			if (frontGroup.active.get() != front)
				frontGroup.active.set(front);
		} else {
			target = current();
			if (focused.get() != target.id)
				focused.set(target.id);
			// Native string signals notify on every write, including equal values.
			if (selected.get() != target.active.get())
				selected.set(target.active.get());
		}
		if (touched)
			changed();
	}

	/** Splits right (horizontal row) or down (vertical column), moving the current tab when possible. */
	public function split(direction:String):Void {
		var source = current(),
			group = new EditorGroup(nextId++),
			file = source.active.get();
		if (source.files.get().length > 1 && file != "") {
			source.files.set(source.files.get().filter(f -> f != file));
			source.active.set(source.files.get()[source.files.get().length - 1]);
			group.files.set([file]);
			group.active.set(file);
		}
		var node = Split({
			direction: direction == "vertical" ? "vertical" : "horizontal",
			first: Group(source),
			second: Group(group),
			ratio: Signal.make(.5)
		});
		layout.set(replace(layout.get(), source.id, node));
		select(group);
		changed();
	}

	public function focusNext(backward = false):Void {
		var groups = all(), at = groups.indexOf(current());
		select(groups[(at + (backward ? groups.length - 1 : 1)) % groups.length]);
	}

	/** Moves the active tab to the next group, preserving the same document instance. */
	public function moveNext():Void {
		var groups = all(), source = current(), file = source.active.get();
		if (groups.length < 2 || file == "")
			return;
		var target = groups[(groups.indexOf(source) + 1) % groups.length];
		source.files.set(source.files.get().filter(f -> f != file));
		source.active.set(source.files.get().length == 0 ? "" : source.files.get()[0]);
		target.files.set(target.files.get().concat([file]));
		target.active.set(file);
		if (source.files.get().length == 0)
			layout.set(remove(layout.get(), source.id));
		select(target);
		changed();
	}

	public function join():Void {
		var groups = all(),
			target = current(),
			files = [for (group in groups) for (file in group.files.get()) file];
		if (groups.length < 2)
			return;
		target.files.set(files);
		layout.set(Group(target));
		select(target);
		changed();
	}

	/** Closing a group keeps its tabs, appended to a surviving neighbor. */
	public function closeGroup():Void {
		var groups = all(), source = current();
		if (groups.length < 2)
			return;
		var target = groups[(groups.indexOf(source) + 1) % groups.length];
		target.files.set(target.files.get().concat(source.files.get()));
		if (source.active.get() != "")
			target.active.set(source.active.get());
		layout.set(remove(layout.get(), source.id));
		select(target);
		changed();
	}

	public function neighbor(file:String):String {
		var group = owner(file);
		if (group == null)
			return "";
		var files = group.files.get(), at = files.indexOf(file);
		return files.length > 1 ? files[at + 1 < files.length ? at + 1 : at - 1] : "";
	}

	public function remap(path:String->String):Void {
		for (group in all()) {
			group.files.set(group.files.get().map(path));
			group.active.set(path(group.active.get()));
		}
		changed();
	}

	public function resize(split:EditorSplit, ratio:Float):Void {
		if (!Math.isFinite(ratio))
			return;
		split.ratio.set(Math.max(.1, Math.min(.9, ratio)));
		changed();
	}

	public function snapshot(path:String->Null<String>):EditorLayoutSession {
		function save(node:EditorNode):EditorLayoutSession
			return switch node {
				case Group(group):
					var files = [for (file in group.files.get()) if (path(file) != null) path(file)];
					var active = path(group.active.get());
					{files: files, active: files.indexOf(active) >= 0 ? active : files.length == 0 ? "" : files[0]};
				case Split(split): {
						direction: split.direction,
						ratio: split.ratio.get(),
						first: save(split.first),
						second: save(split.second)
					};
			};
		return save(layout.get());
	}

	public function restore(saved:Null<EditorLayoutSession>, files:Array<String>, index:Int, path:String->String):Void {
		if (saved == null) {
			sync(files, selected.get());
			return;
		}
		var seen = new Map<String, Bool>();
		function load(data:EditorLayoutSession):Null<EditorNode> {
			if (data.first != null && data.second != null) {
				var first = load(data.first), second = load(data.second);
				return first == null ? second : second == null ? first : Split({
					direction: data.direction,
					ratio: Signal.make(data.ratio ?? .5),
					first: first,
					second: second
				});
			}
			var group = new EditorGroup(nextId++), kept:Array<String> = [];
			for (entry in data.files ?? []) {
				var file = path(entry);
				if (files.indexOf(file) >= 0 && !seen.exists(file)) {
					kept.push(file);
					seen.set(file, true);
				}
			}
			if ((data.files ?? []).length > 0 && kept.length == 0)
				return null;
			group.files.set(kept);
			var front = path(data.active ?? "");
			group.active.set(kept.indexOf(front) >= 0 ? front : kept.length == 0 ? "" : kept[0]);
			return Group(group);
		}
		var restored = load(saved);
		if (restored == null)
			restored = Group(new EditorGroup(nextId++));
		layout.set(restored);
		var groups = all();
		focused.set(groups[index >= 0 && index < groups.length ? index : 0].id);
		sync(files, selected.get());
		changed();
	}

	static function replace(node:EditorNode, id:Int, next:EditorNode):EditorNode
		return switch node {
			case Group(group): group.id == id ? next : node;
			case Split(split): Split({
					direction: split.direction,
					ratio: split.ratio,
					first: replace(split.first, id, next),
					second: replace(split.second, id, next)
				});
		};

	static function remove(node:EditorNode, id:Int):Null<EditorNode>
		return switch node {
			case Group(group): group.id == id ? null : node;
			case Split(split):
				var first = remove(split.first, id),
					second = remove(split.second, id);
				first == null ? second : second == null ? first : Split({
					direction: split.direction,
					ratio: split.ratio,
					first: first,
					second: second
				});
		};
}
