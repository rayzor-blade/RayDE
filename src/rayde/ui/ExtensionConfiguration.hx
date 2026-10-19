package rayde.ui;

import ashui.components.Input;
import ashui.components.Select;
import ashui.components.ToggleSwitch;
import ashui.layout.Element;
import ashui.ui.Component;
import rayde.settings.Extensions;
import rayde.settings.Store;

typedef ExtensionConfigurationProps = {root:String, id:String, schema:Dynamic};

/** Renders the scalar properties contributed by an extension's configuration schema. */
class ExtensionConfiguration extends Component<ExtensionConfigurationProps> {
	function render():Element {
		var groups:Array<Dynamic> = Std.isOfType(props.schema, Array) ? props.schema : [props.schema];
		var fields:Array<Element> = [];
		for (group in groups) {
			var properties = group == null ? null : Reflect.field(group, "properties");
			if (properties == null) continue;
			for (key in Reflect.fields(properties)) {
				var definition = Reflect.field(properties, key);
				if (definition == null) continue;
				var workspace = Store.section(props.root, "extension." + props.id), user = Store.section(Extensions.home(), "extension." + props.id);
				var value:Dynamic = Reflect.hasField(workspace, key) ? Reflect.field(workspace, key) : Reflect.hasField(user, key) ? Reflect.field(user, key) : Reflect.field(definition, "default");
				var choices:Dynamic = Reflect.field(definition, "enum");
				var input:Element, id = "rayde-extension-setting-" + props.id + "-" + ~/[^A-Za-z0-9_-]/g.replace(key, "-");
				if (Std.isOfType(choices, Array)) {
					var options:Array<Element> = [for (option in (choices:Array<Dynamic>)) <select-item value={Std.string(option)}>${Std.string(option)}</select-item>];
					input = <select id={id} value={value == null ? "" : Std.string(value)} size={Sm} class="rayde-control-wide" onChange={text -> {
						var selected:Dynamic = text;
						for (option in (choices:Array<Dynamic>)) if (Std.string(option) == text) selected = option;
						write(key, selected);
					}}>{options}</select>;
				} else if (definition.type == "boolean")
					input = <toggle-switch id={id} checked={value == true} size={Sm} onChange={on -> write(key, on)}/>;
				else if (definition.type == "string" || definition.type == "integer" || definition.type == "number")
					input = <input id={id} height={32} value={value == null ? "" : Std.string(value)} class="rayde-control-wide" onInput={text -> changed(key, definition, text)}/>;
				else continue;
				fields.push(SettingsParts.field(definition.title == null ? key : Std.string(definition.title), definition.description == null ? key : Std.string(definition.description), input));
			}
		}
		return <div class="flex flex-col gap-4">{fields}</div>;
	}

	function changed(key:String, definition:Dynamic, text:String):Void {
		if (definition.type == "string") { write(key, text); return; }
		var number = Std.parseFloat(text);
		if (!Math.isNaN(number) && Math.isFinite(number) && (definition.type != "integer" || Math.floor(number) == number)
			&& (definition.minimum == null || number >= definition.minimum) && (definition.maximum == null || number <= definition.maximum)) write(key, number);
	}

	function write(key:String, value:Dynamic):Void {
		var section = "extension." + props.id, current = Store.section(props.root, section);
		Reflect.setField(current, key, value);
		Store.save(props.root, section, current);
	}
}
