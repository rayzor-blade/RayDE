package rayde.ui;

import ashui.components.CodeEditor;
import ashui.reactive.Signal;
import rayde.ui.Prompt.PromptRequest;

/** What a feature may ask of the workbench it is installed in. It is the whole of the surface features have; they name no workbench member. */
typedef Host = {
	contributions:Contributions,
	/** The project's folder, and what to call this workspace. */
	cwd:String,
	name:String,
	/** The file in front ("" for none), and the files with changes not yet written. */
	active:Signal<String>,
	dirty:Signal<Array<String>>,
	/** Whether the workbench has closed. */
	closed:Void->Bool,
	/** Whether `file` is a text document of this workspace that a feature may work on. */
	isDocument:String->Bool,
	hasBuffer:String->Bool,
	state:String->DocumentState,
	/** The editor of a file that is in front; null for any other. */
	editorOf:String->Null<CodeEditor>,
	open:String->Void,
	say:String->Void,
	ask:PromptRequest->Void,
	/** Tells the workbench that a buffer was changed by something other than typing. */
	edited:String->Void,
	/** Lets go of the text of documents nothing shows any more. */
	releaseDocuments:Void->Void,
	/** The side panel: showing a view of it, folding it away, and whether a view is in it. */
	showSidebar:String->Void,
	hideSidebar:Void->Void,
	sidebarShown:String->Bool
};
