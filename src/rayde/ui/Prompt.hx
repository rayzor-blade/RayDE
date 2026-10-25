package rayde.ui;

import ashui.components.Button;
import ashui.components.Dialog;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.reactive.Watch;
import ashui.ui.Component;
import ashui.ui.Ref;

/** What a prompt asks and what it does with the answer. */
typedef PromptRequest = {
	title:String,
	description:String,
	/** The label of the confirming button. */
	action:String,
	/** Whether it asks for text; without, it asks to confirm. */
	?hasInput:Bool,
	?value:String,
	?placeholder:String,
	/** An error for text that is not acceptable, or null; the prompt stays open and shows it. */
	?check:String->Null<String>,
	/** Whether the confirming button is in the destructive style. */
	?destructive:Bool,
	?alternative:String,
	?discard:Void->Void,
	/** Does it; an exception's text is shown in the prompt, which stays open. */
	accept:String->Void
};

typedef PromptProps = {
	/** The request in force; setting it opens the prompt, and it is set to null when the prompt closes. */
	request:Signal<Null<PromptRequest>>
};

/** A modal that asks for a line of text, or for a confirmation, over the workbench. */
class Prompt extends Component<PromptProps> {
	final open = Signal.make(false);
	final text = Signal.make("");
	final error = Signal.make("");
	final input = new Ref<ashui.ui.Input>();

	function render():Element {
		new Watch(() -> props.request.get(), r -> {
			if (r == null) {
				open.set(false);
				return;
			}
			text.set(r.value == null ? "" : r.value);
			error.set("");
			open.set(true);
			// The field exists once the dialog has been laid out.
			ashui.animation.AnimationScheduler.main.after(.05, () -> {
				var field = input.get();
				if (field != null && open.get() && props.request.get() == r)
					field.focus();
			});
		});
		new Watch(() -> open.get(), o -> if (!o && props.request.get() != null) props.request.set(null));
		return <dialog id="rayde-prompt" open={open}>
			<dialog-content size={Sm}>
				<dialog-header>
					<dialog-title>${props.request.get() == null ? "" : props.request.get().title}</dialog-title>
					<dialog-description>${props.request.get() == null ? "" : props.request.get().description}</dialog-description>
				</dialog-header>
				<for {r in [props.request.get()]}>${body(r)}</for>
				<dialog-footer>
					<dialog-close id="rayde-prompt-cancel">Cancel</dialog-close>
					<for {r in [props.request.get()]}><if {r != null && r.discard != null}><button id="rayde-prompt-discard" onClick={_ -> { r.discard(); props.request.set(null); }}>${r.alternative}</button></if></for>
					<for {r in [props.request.get()]}>${confirm(r)}</for>
				</dialog-footer>
			</dialog-content>
		</dialog>;
	}

	function body(r:Null<PromptRequest>):Element {
		if (r == null || r.hasInput != true)
			return <if {error.get() != ""}><text id="rayde-prompt-error" class="text-xs text-error">${error.get()}</text></if>;
		return <div class="flex flex-col gap-2">
			<input height={32} ref={input} id="rayde-prompt-input" value={text} placeholder={r.placeholder == null ? "" : r.placeholder} class="rayde-control-wide" onKeyDown={e -> if (e.key.match(Named(Enter))) accept()}/>
			<if {error.get() != ""}><text id="rayde-prompt-error" class="text-xs text-error">${error.get()}</text></if>
		</div>;
	}

	function confirm(r:Null<PromptRequest>):Element {
		var label = r == null ? "OK" : r.action;
		if (r != null && r.destructive == true)
			return <button id="rayde-prompt-accept" variant={Destructive} onClick={_ -> accept()}>${label}</button>;
		return <button id="rayde-prompt-accept" variant={Primary} onClick={_ -> accept()}>${label}</button>;
	}

	/** Checks the text, does what was asked, and closes; a refusal or a failure stays in the prompt. */
	public function accept():Void {
		var r = props.request.get();
		if (r == null)
			return;
		var value = text.get();
		if (r.hasInput == true && r.check != null) {
			var why = r.check(value);
			if (why != null) {
				error.set(why);
				return;
			}
		}
		try
			r.accept(value)
		catch (e:Dynamic) {
			error.set(Std.string(e));
			return;
		}
		props.request.set(null);
	}
}
