package rayde.history;

import ashui.components.code.CodeDiffer;
import rayde.history.LocalHistory.Revision;

typedef OwnedText = {text:String, owners:Array<Null<String>>};
typedef HistoryPoint = {id:Int, value:OwnedText};
typedef HistoryJournal = {base:String, baseId:Int, owners:Array<Null<String>>, revisions:Array<Revision>};

/** Data-only line attribution. Missing historical authors stay unknown. */
class LineOwners {
	public static function carry(before:String, after:String, owners:Array<Null<String>>, author:Null<String>):Array<Null<String>> {
		var a = CodeDiffer.split(before), b = CodeDiffer.split(after);
		var result:Array<Null<String>> = [for (_ in b) author], old = 0, next = 0;
		for (change in CodeDiffer.lines(a, b)) {
			while (old < change.originalStart)
				result[next++] = owners[old++];
			old += change.originalLines;
			next += change.modifiedLines;
		}
		while (old < a.length && next < b.length)
			result[next++] = owners[old++];
		return result;
	}

	static function lineCount(text:String, end:Int):Int {
		var count = 1;
		for (i in 0...end)
			if (StringTools.fastCodeAt(text, i) == 10)
				count++;
		return count;
	}

	/** Compare only the patch's touched lines, preserving ownership outside them. */
	public static function patch(source:OwnedText, row:Revision):OwnedText {
		var text = source.text, end = row.from + row.removed.length;
		if (source.owners.length == 0)
			source = {text: text, owners: [for (_ in 0...lineCount(text, text.length)) null]};
		if (row.from < 0 || end > text.length || text.substr(row.from, row.removed.length) != row.removed)
			throw "Invalid history patch";
		if (row.removed == row.inserted)
			return source;
		var start = text.lastIndexOf("\n", row.from - 1) + 1;
		if (row.from == 0)
			start = 0;
		var stop = text.indexOf("\n", end);
		if (stop < 0)
			stop = text.length;
		var first = lineCount(text, start) - 1;
		var before = text.substring(start, stop),
			after = text.substring(start, row.from) + row.inserted + text.substring(end, stop);
		var count = before.split("\n").length;
		var touched = carry(before, after, source.owners.slice(first, first + count), row.author);
		var owners = source.owners.slice(0, first).concat(touched).concat(source.owners.slice(first + count));
		return {text: text.substr(0, row.from) + row.inserted + text.substr(end), owners: owners};
	}

	/** Resume a comparison's ownership from a surviving journal point instead of replaying every edit. */
	public static function latest(journal:HistoryJournal, ?previous:HistoryPoint):HistoryPoint {
		var value:OwnedText, id:Int;
		if (previous != null && (previous.id == journal.baseId || Lambda.exists(journal.revisions, row -> row.id == previous.id))) {
			value = previous.value;
			id = previous.id;
		} else {
			value = {text: journal.base, owners: journal.owners.copy()};
			id = journal.baseId;
		}
		for (row in journal.revisions)
			if (row.id > id) {
				value = patch(value, row);
				id = row.id;
			}
		return {id: id, value: value};
	}

	public static function revision(journal:HistoryJournal, ?id:Int):OwnedText {
		var value:OwnedText = {text: journal.base, owners: journal.owners.copy()};
		if (id == journal.baseId)
			return value;
		for (row in journal.revisions) {
			value = patch(value, row);
			if (id == row.id)
				return value;
		}
		if (id != null)
			throw "Local revision is no longer available";
		return value;
	}
}
