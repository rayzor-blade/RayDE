package rayde.workspace;

typedef TreeEntry = {name:String, directory:Bool};

/** Directory metadata for navigation; file reads and build checks remain authoritative. */
interface TreeWorkspace {
	function treeEntries(path:String):Array<TreeEntry>;
	function refreshTree(path:String):Void;
}
