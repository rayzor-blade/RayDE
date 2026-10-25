package rayde.history;

import ashui.animation.AnimationScheduler;
import ashui.components.code.CodeDiffer;
import ashui.components.code.CodeDiffer.CodeChange;
import ashui.components.code.CodeDiffHint;
import ashui.layout.LayoutTree;
import ashui.reactive.Signal;
import rayde.history.GitHistory.GitFileHistory;
import rayde.history.LineOwners.HistoryJournal;
import rayde.history.LineOwners.HistoryPoint;
import rayde.history.LineOwners.OwnedText;
import rayde.run.Worker;
import rayde.ui.Contributions.ComparisonSource;

typedef ComparisonChoice = {id:String, label:String};
private typedef Catalog = {git:Null<GitFileHistory>, journal:HistoryJournal, fixed:Array<ComparisonSource>, choices:Array<ComparisonChoice>, note:String};

private typedef Request = {
	file:String,
	text:String,
	journal:HistoryJournal,
	jam:Null<ComparisonSource>,
	opened:String,
	catalog:Null<Catalog>,
	base:Null<OwnedText>,
	selected:String,
	?previous:HistoryPoint
};

private typedef Result = {catalog:Catalog, selected:String, base:OwnedText, text:String, hints:Array<CodeDiffHint>, hunks:Array<CodeChange>,
	local:HistoryPoint};

/** One open comparison owns its bounded history data. Only its visible view runs background work. */
class FileComparison {
	public final file:String;
	public final choices = Signal.make(([] : Array<ComparisonChoice>));
	public final selected = Signal.make("");
	public final original = Signal.make("");
	public final modified = Signal.make("");
	public final hints = Signal.make(([] : Array<CodeDiffHint>));
	public final hunks = Signal.make(([] : Array<CodeChange>));
	public final loading = Signal.make(true);
	public final error = Signal.make("");
	public final note = Signal.make("");
	public final layout = Signal.make("inline");

	var opened:String;
	var catalog:Null<Catalog>;
	var base:Null<OwnedText>;
	var previous:Null<HistoryPoint>;
	var latest:Null<Request>;
	var worker:Null<Worker<Request, Result>>;
	var timer:Null<ashui.animation.AnimationScheduler.Timer>;

	public function new(file:String, text:String) {
		this.file = file;
		opened = text;
	}

	public function mount():Void {
		if (worker != null)
			return;
		worker = new Worker<Request, Result>(compare, wake);
		LayoutTree.flushHooks.push(flush);
	}

	public function update(text:String, journal:HistoryJournal, jam:Null<ComparisonSource>):Void {
		latest = {
			file: file,
			text: text,
			journal: journal,
			jam: jam,
			opened: opened,
			catalog: catalog,
			base: base,
			selected: selected.get(),
			previous: previous
		};
		if (worker == null)
			return;
		worker.cancel("file");
		loading.set(true);
		if (timer != null)
			timer.cancel();
		timer = AnimationScheduler.main.after(.12, () -> {
			timer = null;
			submit();
		});
	}

	public function choose(id:String):Void {
		if (selected.get() == id)
			return;
		selected.set(id);
		base = null;
		submit();
	}

	public function refresh():Void {
		catalog = null;
		base = null;
		submit();
	}

	function submit():Void {
		if (worker == null || latest == null)
			return;
		if (timer != null)
			timer.cancel();
		timer = null;
		error.set("");
		loading.set(true);
		latest = {
			file: file,
			text: latest.text,
			journal: latest.journal,
			jam: latest.jam,
			opened: opened,
			catalog: catalog,
			base: base,
			selected: selected.get(),
			previous: previous
		};
		worker.submit("file", latest);
	}

	function flush(_:LayoutTree):Void {
		if (worker == null)
			return;
		for (result in worker.poll()) {
			loading.set(false);
			if (result.error != null) {
				error.set(result.error);
				continue;
			}
			var value = result.value;
			if (latest != null && value.text != latest.text)
				continue;
			catalog = value.catalog;
			base = value.base;
			previous = value.local;
			choices.set(catalog.choices);
			selected.set(value.selected);
			note.set(catalog.note);
			original.set(base.text);
			modified.set(value.text);
			hints.set(value.hints);
			hunks.set(value.hunks);
		}
	}

	public function suspend():Void {
		if (timer != null)
			timer.cancel();
		timer = null;
		if (worker != null)
			worker.dispose();
		worker = null;
		latest = null;
		LayoutTree.flushHooks.remove(flush);
	}

	public function dispose():Void {
		suspend();
		catalog = null;
		base = null;
		previous = null;
		opened = "";
		choices.set([]);
		original.set("");
		modified.set("");
		hints.set([]);
		hunks.set([]);
	}

	static function wake():Void {
		#if ashui_window
		window.Window.wake();
		#end
	}

	static function discover(job:Request, cancelled:Void->Bool):Catalog {
		var git:Null<GitFileHistory> = null, note = "";
		try
			git = GitHistory.load(job.file, cancelled)
		catch (_:Dynamic)
			note = "Git history unavailable; local history is available.";
		if (cancelled())
			throw "Cancelled";
		var fixed:Array<ComparisonSource> = [{id: "opened", label: "Since opening diff", text: job.opened}];
		if (job.jam != null)
			fixed.unshift(job.jam);
		var choices:Array<ComparisonChoice> = [for (source in fixed) {id: source.id, label: source.label}];
		if (git != null) {
			choices.push({id: "git:" + git.head, label: "Git HEAD · " + git.head.substr(0, 7)});
			for (revision in git.revisions)
				if (revision.id != git.head)
					choices.push({id: "git:" + revision.id, label: "Git · " + revision.label});
		} else if (note == "")
			note = "No committed version at this path; comparing local history.";
		choices.push({id: "local:" + job.journal.baseId, label: "Timeline · Original"});
		for (row in job.journal.revisions)
			choices.push({id: "local:" + row.id, label: "Timeline · " + row.kind + " · " + Date.fromTime(row.time).toString()});
		return {
			git: git,
			journal: job.journal,
			fixed: fixed,
			choices: choices,
			note: note
		};
	}

	static function compare(job:Request, cancelled:Void->Bool):Result {
		if (job.text.length > GitHistory.MAX_BYTES)
			throw "This file is too large for history diff.";
		var catalog = job.catalog ?? discover(job, cancelled),
			selected = job.selected,
			base = job.base;
		if (job.jam != null && !Lambda.exists(catalog.fixed, s -> s.id == job.jam.id))
			catalog = {
				git: catalog.git,
				journal: catalog.journal,
				fixed: catalog.fixed.concat([job.jam]),
				choices: [{id: job.jam.id, label: job.jam.label}].concat(catalog.choices),
				note: catalog.note
			};
		if (!Lambda.exists(catalog.choices, c -> c.id == selected)) {
			selected = job.jam != null ? job.jam.id : catalog.git != null ? "git:" + catalog.git.head : "local:" + catalog.journal.baseId;
			base = null;
		}
		if (base == null) {
			if (StringTools.startsWith(selected, "git:")) {
				var git = catalog.git, id = selected.substr(4);
				base = id == git.head ? git.current : GitHistory.read(git.root, git.path, id, cancelled);
			} else if (StringTools.startsWith(selected, "local:"))
				base = LineOwners.revision(catalog.journal, Std.parseInt(selected.substr(6)));
			else {
				var source = Lambda.find(catalog.fixed, s -> s.id == selected);
				base = {text: source.text, owners: []};
			}
		}
		if (cancelled())
			throw "Cancelled";
		if (base.text.length > GitHistory.MAX_BYTES)
			throw "This revision is too large for history diff.";
		var point = LineOwners.latest(job.journal, job.previous),
			local = point.value,
			localOwners = local.text == job.text ? local.owners : LineOwners.carry(local.text, job.text, local.owners, null);
		var owners = catalog.git == null ? localOwners : LineOwners.carry(catalog.git.current.text, job.text, catalog.git.current.owners, null);
		var a = CodeDiffer.split(base.text),
			b = CodeDiffer.split(job.text),
			hunks = CodeDiffer.lines(a, b),
			hints:Array<CodeDiffHint> = [];
		for (change in hunks) {
			for (i in change.originalStart...change.originalStart + change.originalLines)
				hints.push({
					side: "original",
					line: i,
					text: base.owners[i] ?? (StringTools.startsWith(selected, "git:") ? "Unknown author" : "Local history")
				});
			for (i in change.modifiedStart...change.modifiedStart + change.modifiedLines)
				hints.push({side: "modified", line: i, text: owners[i] ?? localOwners[i] ?? "Uncommitted"});
		}
		if (cancelled())
			throw "Cancelled";
		return {
			catalog: catalog,
			selected: selected,
			base: base,
			text: job.text,
			hints: hints,
			hunks: hunks,
			local: point
		};
	}
}
