import rayde.sync.BrowserAccount;
import rayde.sync.ResourceUsage;

class BrowserAccountChecks {
	static function check(ok:Bool,message:String):Void if(!ok)throw message;
	static function main():Void {
		var request=new ash.Future<Dynamic>(),listener:Dynamic->Void=null,changed=0,stopped=false;
		var account=new BrowserAccount(()->request,receive->{listener=receive;return ()->stopped=true;},()->changed++);
		var samples=0,usage=new ResourceUsage(()->{samples++;return new ash.Future<Dynamic>();},()->account.signedIn());
		usage.frame();check(account.state.get().checking&&samples==0,"Unverified account polled private usage or appeared signed out");
		listener({ev:"account.changed",user:{login:"darmie"}});usage.frame();
		check(account.signedIn()&&samples==1,"Browser sign-in did not enable resource usage");
		listener({ev:"account.changed",user:null});request.resolve({result:{user:{login:"stale"}}});account.frame();usage.frame();
		check(!account.signedIn()&&!account.state.get().checking&&samples==1&&changed==2,"A delayed status revived the signed-out account or kept polling usage");
		account.close();usage.close();listener({ev:"account.changed",user:{login:"closed"}});
		check(stopped&&!account.signedIn(),"Disposed browser account retained notifications");
		var failed=new ash.Future<Dynamic>(),other=new BrowserAccount(()->failed,_ -> ()->{},()->{});
		failed.reject("Account service unavailable");other.frame();
		check(!other.state.get().checking&&other.state.get().message=="Account service unavailable"&&!other.signedIn(),"Account errors were presented as a signed-out result");other.close();
		var ready=new ash.Future<Dynamic>(),initial=new BrowserAccount(()->ready,_ -> ()->{},()->{});
		ready.resolve({result:{user:{login:"initial"}}});initial.frame();check(initial.signedIn()&&initial.state.get().login=="initial","An account checked before notifications was lost");initial.close();
		Sys.println("Browser account: asynchronous initial state, sign-in/out, late-response fencing, usage gating, failure and cleanup passed");
	}
}
