import ashui.layout.LayoutTree;
import ashui.reactive.Owner;
import haxe.io.Bytes;
import rayde.ext.GitProfiles;

@:access(rayde.ext.GitProfiles)
class GitProfileChecks {
	static function check(value:Bool, message:String):Void { if (!value) throw message; }
	static function main():Void {
		for (url in ["git@github.com:owner/repo.git", "https://github.com/owner/repo", "ssh://git@github.com:22/owner/repo.git", "https://token@github.com/owner/repo.git"])
			check(GitProfiles.repository(url).path == "owner/repo", "Known remote did not normalize: " + url);
		check(GitProfiles.repository("git@gitlab.com:group/subgroup/project.git").path == "group/subgroup/project", "GitLab subgroup path");
		for (url in ["/tmp/repo", "https://github.com.evil.test/owner/repo", "https://evil.test/github.com/owner/repo", "https://github.com/owner/../repo", "https://github.com/owner/repo?token=secret"])
			check(GitProfiles.repository(url) == null, "Unsupported remote was queryable: " + url);
		check(!GitProfiles.avatarUrl("http://avatars.githubusercontent.com/u/1") && !GitProfiles.avatarUrl("https://avatars.githubusercontent.com.evil.test/u/1"), "Avatar URL must be a known HTTPS provider");
		var sha = [for (_ in 0...40) "a"].join(""), image = Bytes.ofString("compressed-image"), urls:Array<String> = [];
		GitProfiles.request = (url, _) -> {
			urls.push(url);
			if (url.indexOf("api.github.com") >= 0) return Bytes.ofString('[{"author":{"avatar_url":"https://avatars.githubusercontent.com/u/1"}}]');
			if (url.indexOf("gitlab.com/api") >= 0) return Bytes.ofString('{"avatar_url":"https://gitlab.com/uploads/-/system/user/avatar/2/avatar.png"}');
			if (url.indexOf("api.bitbucket.org") >= 0) return Bytes.ofString('{"author":{"user":{"links":{"avatar":{"href":"https://bitbucket.org/account/avatar/3"}}}}}');
			return image;
		};
		for (host in ["github.com", "gitlab.com", "bitbucket.org"]) {
			var result = GitProfiles.lookup({repository:{host:host, path:"owner/repo"}, commit:sha, email:"author+git@example.test", name:"Code Author"}, () -> false);
			check(result != null && result.bytes == image && result.name == "Code Author", host + " public profile response");
		}
		check(urls[2].indexOf("author%2Bgit%40example.test") >= 0, "GitLab public email must be URL encoded");
		var count = urls.length;
		check(GitProfiles.lookup({repository:{host:"github.com", path:"owner/repo"}, commit:sha, email:"a@b.test", name:"A"}, () -> true) == null && urls.length == count, "Cancelled lookup made a request");
		var tree = new LayoutTree(), stop:Void->Void = null, delivered = 0, key = "github.com/owner/repo:author@example.test";
		var profile = {id:sha, remote:"git@github.com:owner/repo.git", author:"Author", email:"author@example.test"};
		Owner.root(tree, cleanup -> {
			stop = cleanup;
			GitProfiles.observe(profile, false, value -> check(value == null, "Capability denial returned a profile"));
			check(GitProfiles.listeners.length == 0, "Capability denial queued network work");
			GitProfiles.observe(profile, true, _ -> delivered++);
			GitProfiles.observe(profile, true, _ -> delivered++);
			return 0;
		});
		var end = haxe.Timer.stamp() + 5;
		while (delivered != 2 && haxe.Timer.stamp() < end) { GitProfiles.flush(tree); Sys.sleep(.005); }
		check(delivered == 2 && urls.length == count + 2, "Concurrent views did not share one provider lookup and download");
		Owner.root(tree, cleanup -> {
			GitProfiles.observe(profile, true, _ -> delivered++); cleanup(); return 0;
		});
		check(delivered == 3 && urls.length == count + 2, "Revisited author did not use the compressed cache");
		stop();
		check(GitProfiles.listeners.length == 0 && !GitProfiles.hooked, "Closed views retained listeners or flush hooks");
		var entered = new sys.thread.Lock(), release = new sys.thread.Lock(), stopped = false;
		GitProfiles.request = (url, _) -> {
			if (url.indexOf("api.github.com") >= 0) { entered.release(); release.wait(); return Bytes.ofString('[{"author":{"avatar_url":"https://avatars.githubusercontent.com/u/1"}}]'); }
			return image;
		};
		Owner.root(tree, cleanup -> {
			stop = cleanup;
			GitProfiles.observe({id:sha, remote:"git@github.com:cancel/repo.git", author:"Closed", email:"closed@example.test"}, true, _ -> stopped = true);
			return 0;
		});
		check(entered.wait(5), "Cancellation fixture did not enter its worker"); stop(); release.release();
		end = haxe.Timer.stamp() + 5;
		while (GitProfiles.worker.busy() && haxe.Timer.stamp() < end) { GitProfiles.flush(tree); Sys.sleep(.005); }
		check(!stopped && GitProfiles.listeners.length == 0 && !GitProfiles.hooked, "Closed owner received a late profile or retained a flush hook");
		GitProfiles.request = (url, _) -> url.indexOf("api.github.com") >= 0
			? Bytes.ofString('[{"author":{"avatar_url":"https://avatars.githubusercontent.com/u/1"}}]') : Bytes.alloc(32768);
		for (i in 0...140) {
			var done = false;
			Owner.root(tree, cleanup -> {
				stop = cleanup;
				GitProfiles.observe({id:sha, remote:"git@github.com:bounded/repo.git", author:"Author", email:'author$i@example.test'}, true, _ -> done = true);
				return 0;
			});
			end = haxe.Timer.stamp() + 5;
			while (!done && haxe.Timer.stamp() < end) { GitProfiles.flush(tree); Sys.sleep(.001); }
			check(done, "Cache pressure lookup did not complete"); stop();
		}
		check(GitProfiles.retained <= 2 * 1024 * 1024 && Lambda.count(GitProfiles.cache) <= 128, "Profile cache exceeded its compressed-byte or entry budget");
		GitProfiles.request = (url, _) -> url.indexOf("/users/unpublished") >= 0
			? Bytes.ofString('{"avatar_url":"https://avatars.githubusercontent.com/u/1"}') : url.indexOf("avatars.githubusercontent.com") >= 0 ? image : null;
		check(GitProfiles.lookup({repository:{host:"github.com", path:"private/repo"}, commit:sha, email:"123+unpublished@users.noreply.github.com", name:"Author"}, () -> false) != null, "Unpushed commit could not use its public GitHub noreply account");
		GitProfiles.request = (_, _) -> null;
		check(GitProfiles.lookup({repository:{host:"github.com", path:"private/repo"}, commit:sha, email:"a@b.test", name:"A"}, () -> false) == null, "Unavailable profiles must fall back quietly");
		var wake = new sys.thread.Lock();
		var worker = new rayde.run.Worker<Int, Int>((value, _) -> value + 1, wake.release);
		worker.submit("ready", 4);
		check(wake.wait(5), "Worker did not notify after completion");
		check(worker.poll()[0].value == 5, "Worker woke before publishing its result"); worker.dispose();
		tree.dispose();
		Sys.println("Git profiles: known remotes, public provider adapters, capability checks, cancellation, request sharing, compressed cache and completion wakes");
	}
}
