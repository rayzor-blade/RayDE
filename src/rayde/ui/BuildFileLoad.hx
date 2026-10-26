package rayde.ui;

import ashui.reactive.Signal;
import rayde.build.HxmlFile;
import rayde.run.Worker;

typedef BuildFileState = {path:Null<String>, file:Null<HxmlFile>, loading:Bool, error:Null<String>};

/** The settings tab owns a build-file read; only completed data reaches its views. */
class BuildFileLoad {
	public final state = Signal.make(({path:null,file:null,loading:false,error:null}:BuildFileState));
	final worker = new Worker<String,HxmlFile>((path,_) -> HxmlFile.read(path),ashui.core.Work.notify);

	public function new() {}

	public function load(path:Null<String>):Void {
		worker.cancel("build");
		state.set({path:path,file:null,loading:path != null,error:null});
		if (path != null) worker.submit("build",path);
	}

	public function poll():Void {
		for (result in worker.poll()) {
			var path = state.get().path;
			if (result.error != null) Sys.println('Could not load "$path": ' + result.error);
			state.set({path:path,file:result.value,loading:false,error:result.error});
		}
	}

	public function cancel():Void {
		worker.cancel("build");
		state.set({path:null,file:null,loading:false,error:null});
	}

	public function dispose():Void worker.dispose();
}
