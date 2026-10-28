package rayde.ui;

import ashui.components.Button;
import ashui.components.Select;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.run.RunConfigurations;
import rayde.run.RunConfigurations.RunConfiguration;
import rayde.run.RunPresets;

class RunConfigurationSettings extends Component<{root:String,?target:String,?family:String,?onChanged:Void->Void}> {
 final selected=Signal.make("hl");
 final preview=Signal.make(false);
 final revision=Signal.make(0);
 final error=Signal.make("");
 var configuration:RunConfiguration;
 function render():Element {
  selected.set(activeTarget());load();
  return <div id="rayde-run-configuration" class="flex flex-col gap-3">
   <for {r in [revision.get()]}>${form()}</for>
   <if {error.get()!=""}><text id="rayde-run-config-error" class="text-sm text-error">${error.get()}</text></if>
  </div>;
 }
 function activeTarget():String {
  var section=rayde.settings.Store.section(props.root,"run");
  var saved:Dynamic=preview.get() && section.previewTarget!=null ? section.previewTarget : section.target;
  return props.target ?? (Std.isOfType(saved,String) ? saved : props.family=="rayzor" ? "native" : "hl");
 }
 function purpose(value:String):Void {preview.set(value=="preview");if(props.family=="rayzor")selected.set(activeTarget());load();revision.set(revision.get()+1);}
 function load():Void {
  try {configuration=RunConfigurations.load(props.root,selected.get(),preview.get(),props.family);error.set("");}
  catch(failure:Dynamic){configuration=RunPresets.make(props.family=="rayzor" ? "rayzor" : "haxe",selected.get(),preview.get());error.set(Std.string(failure));}
 }
 function form():Element {
  var fields:Array<Element>=[];
  var choices=props.family=="rayzor" ? RunConfigurations.rayzorTargets.copy() : RunConfigurations.targets.copy();
  if(choices.indexOf(selected.get())<0)choices.push(selected.get());
  fields.push(field("Target",props.family=="rayzor" ? "Rayzor target triple or WASM selector" : "The compiler target this configuration applies to",<select id="rayde-run-config-target" value={selected} class="rayde-control" onChange={pickTarget}>{[for(target in choices)<select-item value={target}>${target}</select-item>]}</select>));
  if(props.family=="rayzor")fields.push(textField("triple","Target triple","Enter another LLVM target triple",selected.get(),value -> pickTarget(value)));
  fields.push(field("Launch","Run and Preview share these target settings",<select id="rayde-run-config-purpose" value={preview.get() ? "preview" : "run"} class="rayde-control" onChange={purpose}><select-item value="run">Run</select-item><select-item value="preview">Browser Preview</select-item></select>));
  var frameworks=props.family=="rayzor" ? ["rayzor","custom"] : RunConfigurations.frameworks.filter(value -> value!="rayzor" && value!="caribou");if(frameworks.indexOf(configuration.framework)<0)frameworks.push(configuration.framework);
  fields.push(field("Framework","Selecting a framework applies an editable preset",<select id="rayde-run-config-framework" value={configuration.framework} class="rayde-control" onChange={applyPreset}>{[for(framework in frameworks)<select-item value={framework}>${label(framework)}</select-item>]}</select>));
  if(props.family!="rayzor")fields.push(field("Compiler","Framework commands may invoke their own compiler",<select id="rayde-run-config-compiler" value={configuration.compiler} class="rayde-control" onChange={value -> edit(() -> configuration.compiler=value)}>{[for(compiler in ["haxe","custom"])<select-item value={compiler}>${label(compiler)}</select-item>]}</select>));
  else fields.push(<text class="text-xs text-text-secondary">Rayzor compiles this project directly. Haxe source backends do not apply.</text>);
  fields.push(field("Mode","Run a program, compile a native executable, or produce browser output",<select id="rayde-run-config-mode" value={configuration.mode} class="rayde-control" onChange={value -> edit(() -> configuration.mode=value)}><select-item value="process">Run</select-item><if {selected.get()=="hl" || props.family=="rayzor"}><select-item value="aot">Native AOT</select-item></if><select-item value="browser">Browser</select-item></select>));
  fields.push(field("Runner","The runtime or compiler driver for this target",<select id="rayde-run-config-runner" value={configuration.runner} class="rayde-control" onChange={value -> edit(() -> {configuration.runner=value;configuration.flags=RunConfigurations.defaults(selected.get(),configuration.mode=="browser",value).flags;})}>{[for(runner in RunConfigurations.runners)<select-item value={runner}>${label(runner)}</select-item>]}</select>));
  fields.push(textField("executable","Executable","Leave empty to use the runner's default",configuration.executable,value -> edit(() -> configuration.executable=value)));
  fields.push(argsField("flags","Runner flags","Quoted arguments are supported",configuration.flags,value -> configuration.flags=value));
  fields.push(argsField("arguments","Program arguments","Passed to the launched program",configuration.arguments,value -> configuration.arguments=value));
  fields.push(argsField("compiler-flags","Compiler flags","Additional compiler arguments for this target",configuration.compilerFlags,value -> configuration.compilerFlags=value));
  fields.push(textField("build-command","Build command","Optional framework compiler command",configuration.buildCommand,value -> edit(() -> configuration.buildCommand=value)));
  fields.push(argsField("build-flags","Build / AOT arguments","Compiler driver flags; {target}, {root} and {output} are available",configuration.buildFlags,value -> configuration.buildFlags=value));
  fields.push(textField("program","Program file","Optional override when the target's executable needs another path",configuration.program,value -> edit(() -> configuration.program=value)));
  if(preview.get()||configuration.mode=="browser"){
   fields.push(textField("preview-directory","Preview directory","Framework web output or additional browser assets",configuration.previewDirectory,value -> edit(() -> configuration.previewDirectory=value)));
   fields.push(textField("preview-entry","Preview entry","HTML entry within that directory",configuration.previewEntry,value -> edit(() -> configuration.previewEntry=value)));
  }
  return SettingsParts.card("rayde-run-configuration-card","Run Configuration","Settings are saved for this workspace. Press Enter to save text fields.",fields);
 }
 static function label(value:String):String return switch value {case "haxe":"Haxe";case "ash":"Ash";case "ashui":"Ashui";case "hashlink":"HashLink";case "js":"JavaScript";case "openfl":"OpenFL";case "flixel":"HaxeFlixel";case "tink":"Tink / Coconut";case "auto":"Automatic";case "aot":"Native AOT";case _:value.charAt(0).toUpperCase()+value.substr(1);};
 static function field(name:String,hint:String,control:Element):Element return SettingsParts.field(name,hint,control);
 function textField(id:String,name:String,hint:String,value:String,save:String->Void):Element {
  var text=Signal.make(value);
  return field(name,hint,<input id={"rayde-run-config-"+id} height={32} class="rayde-control" value={text} onKeyDown={event -> if(event.key.match(Named(Enter)))save(text.get())}/>);
 }
 function argsField(id:String,name:String,hint:String,value:Array<String>,save:Array<String>->Void):Element return textField(id,name,hint,RunConfigurations.format(value),text -> {
  try {var parsed=RunConfigurations.parse(text);edit(() -> save(parsed));}catch(failure:Dynamic)error.set(Std.string(failure));
 });
 function pickTarget(value:String):Void {
  if(!~/^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,79}$/.match(value)){error.set("Invalid target name.");return;}
  selected.set(value);load();
  if(props.family=="rayzor"||props.target==null){try {var section=rayde.settings.Store.section(props.root,"run");Reflect.setField(section,preview.get() ? "previewTarget" : "target",value);rayde.settings.Store.saveChecked(props.root,"run",section);if(props.onChanged!=null)props.onChanged();}catch(failure:Dynamic)error.set(Std.string(failure));}
  revision.set(revision.get()+1);
 }
 function applyPreset(framework:String):Void {
  configuration=RunPresets.make(props.family=="rayzor" ? "rayzor" : framework,selected.get(),preview.get());configuration.framework=framework;
  edit(() -> {});
 }
 function edit(change:Void->Void):Void {
  try {change();RunConfigurations.save(props.root,configuration,preview.get());error.set("");revision.set(revision.get()+1);if(props.onChanged!=null)props.onChanged();}
  catch(failure:Dynamic)error.set(Std.string(failure));
 }
}
