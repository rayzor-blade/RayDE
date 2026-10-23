package rayde.run;

/** Explicit HXML targets stay intact; shared configuration files use Run's bytecode target. */
class HaxeBuild {
	static final modes = ["-hl", "--hl", "-js", "--js", "-cpp", "--cpp", "-cppia", "--cppia", "-neko", "--neko", "-lua", "--lua", "-php", "--php", "-python", "--python", "-java", "--java", "-jvm", "--jvm", "-cs", "--cs", "-swf", "--swf", "--interp", "--run", "-x", "--no-output", "-xml", "--xml"];
	public static function plan(file:String, output:String):{args:Array<String>, implicit:Bool} {
		var args = rayde.lang.Hxml.readAll(file);
		if (Lambda.exists(args, arg -> modes.indexOf(arg) >= 0)) return {args:[file], implicit:false};
		if (args.indexOf("--next") >= 0) throw "This HXML has multiple compilations but no target. Set their targets in Build Settings or the HXML file.";
		return {args:[file, "-hl", output], implicit:true};
	}
}
