import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import haxe.io.Bytes;
import rayde.ext.GitAvatarCache;
import rayde.ext.GitProfiles;
import sys.FileSystem;
import sys.io.File;

@:access(rayde.ext.GitProfiles)
class GitAvatarCacheChecks {
	static final sha = [for (_ in 0...40) "a"].join("");
	static final email = "avatar-cache@example.test";
	static function check(value:Bool, message:String):Void { if (!value) throw message; }
	static function key(email:String):String
		return GitProfiles.identity({host:"github.com",path:"owner/repo"},sha,email);
	static function job(directory:String, email:String):Dynamic
		return {repository:{host:"github.com",path:"owner/repo"},commit:sha,email:email,name:"Public Author",directory:directory};
	static function stale(directory:String, email:String):Void {
		var file = GitAvatarCache.path(directory,key(email));
		var value:Dynamic = haxe.Json.parse(File.getContent(file));
		value.saved = Sys.time() - GitAvatarCache.FRESH_SECONDS - 1;
		File.saveContent(file,haxe.Json.stringify(value));
	}
	static function observe(email:String):Null<rayde.ext.GitProfiles.GitProfile> {
		var tree = new LayoutTree(), stop:Void->Void = null, done = false, result = null;
		Owner.root(tree, cleanup -> {
			stop = cleanup;
			GitProfiles.observe({id:sha,remote:"https://github.com/another/repository.git",author:"Public Author",email:email},true,value -> { result = value; done = true; });
			return 0;
		});
		var deadline = haxe.Timer.stamp() + 5;
		while (!done && haxe.Timer.stamp() < deadline) { GitProfiles.flush(tree); Sys.sleep(.001); }
		stop(); tree.dispose();
		check(done,"Avatar worker did not deliver its result");
		check(GitProfiles.listeners.length == 0 && !GitProfiles.hooked,"Avatar cache retained a UI owner");
		return result;
	}
	static function main():Void {
		var args = Sys.args(), offline = args[0] == "--offline";
		var directory = offline ? args[1] : args[0];
		if (directory == null) directory = 'bin/git-avatar-cache-${Std.random(0x3fffffff)}';
		GitProfiles.directory = () -> directory;
		var image = File.getBytes("tests/fixtures/images/sample.jpg"), calls = 0;
		function network():Void {
			GitProfiles.request = (url,_) -> {
				calls++;
				return url.indexOf("api.github.com") >= 0 ? Bytes.ofString('[{"author":{"avatar_url":"https://avatars.githubusercontent.com/u/1"}}]') : image;
			};
		}
		if (offline) {
			GitProfiles.request = (_,_) -> { calls++; throw "Network must not be needed after restart"; };
			check(Lambda.count(GitProfiles.cache) == 0,"Restart probe began with a warm memory cache");
			var result = observe(email.toUpperCase());
			check(result != null && result.bytes.compare(image) == 0 && calls == 0,"Fresh process did not restore its avatar offline");
			Sys.println("Git avatar restart: empty memory cache restored the saved image with no network requests");
			return;
		}
		var previous = GitAvatarCache.path(directory,key(email));
		if (FileSystem.exists(previous)) FileSystem.deleteFile(previous);
		network();
		var first = GitProfiles.lookup(job(directory,email),() -> false);
		check(first != null && calls == 2 && GitAvatarCache.read(directory,key(email)) != null,"Successful avatar was not persisted");
		GitProfiles.request = (_,_) -> { calls++; throw "Fresh disk cache made a request"; };
		var other = job(directory,email.toUpperCase()); other.repository.path = "another/repository";
		var reused = GitProfiles.lookup(other,() -> false);
		check(reused != null && reused.bytes.compare(image) == 0 && calls == 2,"Repositories did not share the saved provider/author image");
		check(GitProfiles.identity({host:"github.com",path:"owner/repo"},sha,"") != GitProfiles.identity({host:"github.com",path:"other/repo"},sha,""),"Missing emails merged unrelated repository identities");
		var tree = new LayoutTree();
		Owner.root(tree, cleanup -> {
			GitProfiles.observe({id:sha,remote:"https://github.com/owner/repo",author:"Author",email:email},false,value -> check(value == null,"Capability denial exposed a cached avatar"));
			cleanup(); return 0;
		});
		tree.dispose();
		stale(directory,email);
		GitProfiles.request = (_,_) -> null;
		check(GitProfiles.lookup(job(directory,email),() -> false).bytes.compare(image) == 0,"Offline refresh discarded the last saved image");
		GitProfiles.request = (_,_) -> { throw "Network failure"; };
		check(GitProfiles.lookup(job(directory,email),() -> false).bytes.compare(image) == 0,"Failed refresh discarded the last saved image");
		check(GitProfiles.lookup(job(directory,email),() -> true) == null,"Cancelled lookup delivered a saved image");
		network();
		var file = GitAvatarCache.path(directory,key(email));
		var corrupt:Dynamic = haxe.Json.parse(File.getContent(file));
		corrupt.image = haxe.crypto.Base64.encode(Bytes.ofString("damaged"));
		File.saveContent(file,haxe.Json.stringify(corrupt));
		var before = calls;
		check(GitProfiles.lookup(job(directory,email),() -> false).bytes.compare(image) == 0 && calls == before + 2,"Corrupt cache bytes did not trigger a new download");
		File.saveContent(file,"{partial"); before = calls;
		check(GitProfiles.lookup(job(directory,email),() -> false) != null && calls == before + 2,"Partial cache file did not recover");
		FileSystem.createDirectory(directory);
		var unavailable = directory + "/not-a-directory"; File.saveContent(unavailable,"file");
		check(GitProfiles.lookup(job(unavailable,"io@example.test"),() -> false) != null,"Cache I/O failure prevented a public lookup");
		GitProfiles.directory = () -> null;
		check(observe("memory@example.test") != null,"Memory fallback fixture did not load");
		GitProfiles.cache.get(key("memory@example.test")).until = 0;
		GitProfiles.request = (_,_) -> null;
		check(observe("memory@example.test").bytes.compare(image) == 0,"Failed refresh erased a successful in-memory avatar");
		var bounded = directory + "/bounded";
		for (i in 0...130) GitAvatarCache.save(bounded,'entry$i',{name:"Author",bytes:Bytes.ofString("small")});
		File.saveContent(bounded + "/unrelated.txt","keep");
		check([for (name in FileSystem.readDirectory(bounded)) if (StringTools.endsWith(name,".json")) name].length <= 128,"Disk cache exceeded its entry budget");
		for (i in 0...36) GitAvatarCache.save(bounded,'large$i',{name:"Author",bytes:Bytes.alloc(256 * 1024)});
		var size = 0;
		for (name in FileSystem.readDirectory(bounded)) if (StringTools.endsWith(name,".json")) size += FileSystem.stat(bounded + "/" + name).size;
		check(size <= 8 * 1024 * 1024 && File.getContent(bounded + "/unrelated.txt") == "keep","Disk cache exceeded its byte budget or removed an unrelated file");
		GitAvatarCache.save(directory,key(email),{name:"Public Author",bytes:image});
		Sys.println("Git avatar cache: persistent author sharing, offline fallback, cancellation, corruption recovery, failed refresh preservation and disk budgets");
	}
}
