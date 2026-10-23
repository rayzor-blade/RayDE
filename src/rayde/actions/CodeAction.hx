package rayde.actions;

/** Offsets use the editor's string positions; the upper bound is exclusive. */
typedef ActionRange = {from:Int, to:Int};
typedef ActionEdit = {from:Int, to:Int, text:String};
typedef ActionDiagnostic = {from:Int, to:Int, message:String, severity:Int};

/** One active document snapshot. Providers never receive an editor or a retained tab. */
typedef ActionContext = {
	path:String, language:String, text:String, version:Int, range:ActionRange,
	trigger:String, diagnostics:Array<ActionDiagnostic>
};

typedef CodeAction = {
	id:String, title:String, kind:String, range:ActionRange,
	?icon:String, ?preferred:Bool, ?disabled:String,
	?command:String, ?arguments:Dynamic, ?edits:Array<ActionEdit>
};

typedef ActionRequest = {request:String, provider:String, context:ActionContext};
typedef ActionItem = {key:String, provider:String, action:CodeAction};
