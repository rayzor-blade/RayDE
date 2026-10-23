package rayde.ext;

import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import haxe.io.Bytes;
import rayde.run.Worker;

typedef GitProfile = {name:String, bytes:Bytes};
private typedef Repository = {host:String, path:String};
private typedef Request = {repository:Repository, commit:String, email:String, name:String};
private typedef Cached = {profile:Null<GitProfile>, until:Float};
private typedef Listener = {key:String, owner:Owner, done:Null<GitProfile>->Void};

/** Public provider lookups keep compressed bytes only; visible UI owners own decoded images. */
class GitProfiles {
	static final worker = new Worker<Request, Null<GitProfile>>(lookup, wake);
	static final cache = new Map<String, Cached>();
	static final recent:Array<String> = [];
	static final pending = new Map<String, Bool>();
	static final listeners:Array<Listener> = [];
	static final blocked = new Map<String, Float>();
	static var hooked = false;
	static var retained = 0;
	static inline var MAX_BYTES = 2 * 1024 * 1024;
	static var request:(String, Int)->Null<Bytes> = http;
	static var status = 0;

	public static function observe(data:Dynamic, allowed:Bool, done:Null<GitProfile>->Void):Void {
		var repo = data == null ? null : repository(field(data, "remote"));
		var commit = field(data, "id"), email = field(data, "email"), name = field(data, "author");
		if (!allowed || repo == null || !~/^[a-fA-F0-9]{40,64}$/.match(commit)) { done(null); return; }
		var key = repo.host + "/" + repo.path + ":" + (email == "" ? commit : email.toLowerCase());
		var known = cache.get(key), now = haxe.Timer.stamp();
		if (known != null && known.until > now) { touch(key); done(known.profile); return; }
		if (!pending.exists(key) && Lambda.count(pending) >= 64) { done(null); return; }
		var listener = {key:key, owner:Owner.current, done:done};
		listeners.push(listener);
		Owner.onCleanup(() -> {
			listeners.remove(listener);
			if (!Lambda.exists(listeners, l -> l.key == key)) { worker.cancel(key); pending.remove(key); }
			unhook();
		});
		if (!hooked) { LayoutTree.flushHooks.push(flush); hooked = true; }
		if (!pending.exists(key)) {
			pending.set(key, true);
			worker.submit(key, {repository:repo, commit:commit, email:email, name:name});
		}
	}

	static function wake():Void {
		#if ashui_window
		window.Window.wake();
		#end
	}

	static function flush(_:LayoutTree):Void {
		for (result in worker.poll()) {
			pending.remove(result.key);
			var previous = cache.get(result.key);
			if (previous != null && previous.profile != null) retained -= previous.profile.bytes.length;
			var profile = result.value;
			cache.set(result.key, {profile:profile, until:haxe.Timer.stamp() + (profile == null ? 600 : 86400)});
			if (profile != null) retained += profile.bytes.length;
			touch(result.key);
			while (recent.length > 128 || retained > MAX_BYTES) {
				var old = recent.shift(), entry = cache.get(old);
				if (entry != null && entry.profile != null) retained -= entry.profile.bytes.length;
				cache.remove(old);
			}
			for (listener in listeners.copy()) if (listener.key == result.key) {
				listeners.remove(listener);
				@:privateAccess if (!listener.owner.disposed) listener.owner.run(() -> listener.done(profile));
			}
		}
		unhook();
	}

	static function unhook():Void {
		if (hooked && listeners.length == 0) { LayoutTree.flushHooks.remove(flush); hooked = false; }
	}
	static function touch(key:String):Void { recent.remove(key); recent.push(key); }
	static function field(data:Dynamic, name:String):String {
		var value = data == null ? null : Reflect.field(data, name);
		return Std.isOfType(value, String) ? value : "";
	}

	static function repository(remote:String):Null<Repository> {
		if (remote.length > 4096) return null;
		var match = ~/^(?:(?:https?|ssh|git):\/\/(?:[^\/@]+@)?|(?:[^\/@:]+@)?)(github\.com|gitlab\.com|bitbucket\.org)(?::[0-9]+)?[\/:]([^?#]+)$/i;
		if (!match.match(remote)) return null;
		var host = match.matched(1).toLowerCase(), path = match.matched(2);
		while (StringTools.endsWith(path, "/")) path = path.substr(0, path.length - 1);
		if (StringTools.endsWith(path, ".git")) path = path.substr(0, path.length - 4);
		var parts = path.split("/");
		if (parts.length < 2 || host != "gitlab.com" && parts.length != 2) return null;
		for (part in parts) if (part == "." || part == ".." || !~/^[A-Za-z0-9_.-]+$/.match(part)) return null;
		return {host:host, path:path};
	}

	static function lookup(job:Request, cancelled:Void->Bool):Null<GitProfile> {
		var repo = job.repository;
		if (cancelled() || blocked.exists(repo.host) && blocked.get(repo.host) > haxe.Timer.stamp()) return null;
		var url = switch repo.host {
			case "github.com": 'https://api.github.com/repos/${repo.path}/commits?sha=${job.commit}&per_page=1';
			case "gitlab.com": 'https://gitlab.com/api/v4/avatar?email=${StringTools.urlEncode(job.email)}&size=64';
			case "bitbucket.org": 'https://api.bitbucket.org/2.0/repositories/${repo.path}/commit/${job.commit}';
			case _: return null;
		};
		status = 0;
		var bytes = request(url, 256 * 1024);
		if (status == 403 || status == 429) { blocked.set(repo.host, haxe.Timer.stamp() + 600); return null; }
		if (cancelled()) return null;
		var value:Dynamic = bytes == null ? null : try haxe.Json.parse(bytes.toString()) catch (_:Dynamic) null;
		var avatar = "", name = job.name;
		switch repo.host {
			case "github.com":
				if (Std.isOfType(value, Array) && (value:Array<Dynamic>).length > 0 && value[0].author != null)
					avatar = field(value[0].author, "avatar_url");
				else avatar = githubAccount(job.email, cancelled);
			case "gitlab.com": if (value != null) avatar = field(value, "avatar_url");
			case "bitbucket.org":
				var user:Dynamic = value == null || value.author == null ? null : value.author.user;
				if (user == null || user.links == null || user.links.avatar == null) return null;
				avatar = field(user.links.avatar, "href");
		}
		if (!avatarUrl(avatar) || cancelled()) return null;
		if (repo.host == "github.com") avatar += avatar.indexOf("?") < 0 ? "?s=64" : "&s=64";
		var image = request(avatar, 256 * 1024);
		return image == null || cancelled() ? null : {name:name, bytes:image};
	}

	static function githubAccount(email:String, cancelled:Void->Bool):String {
		var noreply = ~/^(?:[0-9]+\+)?([A-Za-z0-9-]{1,39})@users\.noreply\.github\.com$/i;
		var login = noreply.match(email) ? noreply.matched(1) : null;
		if (login == null && ~/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.match(email)) {
			var found = request("https://api.github.com/search/users?q=" + StringTools.urlEncode('"' + email + '" in:email') + "&per_page=1", 64 * 1024);
			var users:Dynamic = found == null ? null : try haxe.Json.parse(found.toString()) catch (_:Dynamic) null;
			if (users != null && users.total_count == 1 && users.items != null && users.items.length == 1) login = field(users.items[0], "login");
		}
		if (login == null || !~/^[A-Za-z0-9-]{1,39}$/.match(login) || cancelled()) return "";
		var bytes = request("https://api.github.com/users/" + login, 64 * 1024);
		var user:Dynamic = bytes == null ? null : try haxe.Json.parse(bytes.toString()) catch (_:Dynamic) null;
		if (user == null || !noreply.match(email) && field(user, "email").toLowerCase() != email.toLowerCase()) return "";
		return field(user, "avatar_url");
	}

	static function avatarUrl(url:String):Bool {
		var match = ~/^https:\/\/([a-zA-Z0-9.-]+)\//;
		if (!match.match(url)) return false;
		var host = match.matched(1).toLowerCase();
		return ["avatars.githubusercontent.com", "gitlab.com", "secure.gravatar.com", "www.gravatar.com", "gravatar.com", "bitbucket.org"].indexOf(host) >= 0
			|| StringTools.endsWith(host, ".atl-paas.net") || host == "gitlab-production-user-content.s3.amazonaws.com";
	}

	/** Bounded, unauthenticated HTTPS reads run only on the profile worker. */
	static function http(url:String, limit:Int):Null<Bytes> {
		var process:sys.io.Process = null;
		try {
			process = new sys.io.Process("curl", ["--disable", "--silent", "--fail", "--location", "--max-redirs", "2", "--proto", "=https", "--proto-redir", "=https",
				"--connect-timeout", "2", "--max-time", "4", "--max-filesize", Std.string(limit), "--user-agent", "RayDE/0.1", "--write-out", "%{stderr}%{http_code}", "--url", url]);
			var output = new haxe.io.BytesOutput(), chunk = Bytes.alloc(8192);
			try while (true) {
				var count = process.stdout.readBytes(chunk, 0, chunk.length);
				if (output.length + count > limit) { process.kill(); process.close(); return null; }
				output.writeBytes(chunk, 0, count);
			} catch (_:haxe.io.Eof) {}
			var code = process.exitCode(); status = Std.parseInt(process.stderr.readAll().toString()) ?? 0; process.close(); process = null;
			return code == 0 ? output.getBytes() : null;
		} catch (_:Dynamic) { if (process != null) { try process.kill() catch (_:Dynamic) {} process.close(); } return null; }
	}
}
