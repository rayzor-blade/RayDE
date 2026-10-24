package rayde.ui;

/** The features built into RayDE, each installing itself into a workbench through its `Host`. This is the one place that names them. */
class Features {
	public static final builtin:Array<Host->Void> = [
		rayde.jam.JamFeature.install
	];

	public static function installAll(host:Host):Void
		for (install in builtin) install(host);
}
