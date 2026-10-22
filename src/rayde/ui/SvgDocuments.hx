package rayde.ui;

import ashui.svg.SvgDocument;

/** Document SVGs share interned markup while mounted, without retaining it after their last view. */
class SvgDocuments {
	static final owned:Map<Int, {document:SvgDocument, uses:Int}> = [];

	public static function acquire(markup:String):SvgDocument {
		var next = @:privateAccess SvgDocument.nextId;
		var doc = SvgDocument.parse(markup), entry = owned.get(doc.id);
		if (entry != null) entry.uses++;
		else if (doc.id >= next) owned.set(doc.id, {document:doc, uses:1});
		return doc;
	}

	public static function release(doc:SvgDocument):Void {
		var entry = owned.get(doc.id);
		if (entry == null || --entry.uses > 0) return;
		owned.remove(doc.id);
		doc.dispose();
	}
}
