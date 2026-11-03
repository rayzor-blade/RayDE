import ashui.core.render.Offscreen;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Owner;
import rayde.ui.AccountControl;

@:access(rayde.ui.AccountControl)
class AccountControlChecks {
	static function check(ok:Bool,message:String):Void {if(!ok)throw message;}
	static function main():Void {
		for(dark in [true,false])for(width in [480,1280])run(dark,width);
		Sys.println("account menu: asynchronous status, username, Manage access, sign-out guard, pending feedback, failure/retry, cancellation and cleanup in both themes");
	}
	static function run(dark:Bool,width:Int):Void {
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(),dark?Dark:Light);rayde.ui.Style.use();
		var tree=new LayoutTree(),stop:Void->Void=null,control:AccountControl=null,listener:Dynamic->Void=null,unsubscribed=false;
		var requests:Array<{op:String,future:ash.Future<Dynamic>}>=[],messages:Array<String>=[],approved:Void->Void=null;
		var root=Owner.root(tree,cleanup->{stop=cleanup;return <div id="rayde" widthPercent={1} heightPercent={1}><div height={40} widthPercent={1} class="flex flex-row items-center px-3"><div class="flex-1"/>${control=new AccountControl({
			beforeSignOut:proceed->approved=proceed,say:messages.push,
			request:(op,_)->{var f=new ash.Future<Dynamic>();requests.push({op:op,future:f});return f;},
			subscribe:receive->{listener=receive;return ()->unsubscribed=true;}
		})}</div></div>;});
		function settle(frames=4):Void for(_ in 0...frames){Offscreen.advance(.025);Css.setViewport(width,400);Css.update();tree.flush();tree.computeLayout(root.node,width,400);}
		function nodes(selector:String)return Css.query(tree,root.node.id,selector);
		function click(selector="#rayde-account-action"):Void{var ids=nodes(selector);check(ids.length==1,"Missing "+selector);var b=tree.getScrolledBounds(new Node(ids[0]));ashui.input.Pointer.move(tree,b.x+b.width/2,b.y+b.height/2);ashui.input.Pointer.press(tree);ashui.input.Pointer.release(tree);settle();}
		function signOut():Void {click("#rayde-account-trigger");click("#rayde-account-signout");}
		try {
			check(requests.length==0,"Header queried account before mounting");settle();check(requests.length==1&&requests[0].op=="account.status"&&control.busy.get(),"Account check lacks pending feedback");
			var b=tree.getScrolledBounds(new Node(nodes("#rayde-account")[0]));check(b.x>width/2&&b.x+b.width<=width&&b.height>0&&b.height<=40,"Account control is not at the right edge of the header: "+Std.string(b));
			requests[0].future.resolve({result:{user:{login:"alice"}}});settle();check(!control.busy.get()&&control.user.get().login=="alice","Header did not consume account status");
			click("#rayde-account-trigger");check(control.menu.get(),"Account trigger did not open a menu");
			var panel=tree.getScrolledBounds(new Node(nodes("#rayde-account-menu")[0]));check(panel.x>=0&&panel.x+panel.width<=width+1,"Account menu extends beyond the viewport");
			if(dark&&width==1280||!dark&&width==480)ashui.core.render.Snapshot.capture('account-menu-${dark?"dark":"light"}-$width',tree,root.node,width,400,ashui.theme.ThemeState.get().color(Background).rgb());
			click("#rayde-account-manage");check(requests[1].op=="account.manage-access"&&!control.menu.get(),"Manage access was not dispatched or did not close the menu");requests[1].future.resolve(haxe.Json.parse('{"result":{}}'));settle();check(control.user.get().login=="alice","Manage access discarded the signed-in user");
			settle(40);check(requests.length==2&&control.timer==null,"Idle header kept polling account data");
			listener({ev:"account.changed",user:{login:"updated"}});settle();check(control.user.get().login=="updated"&&ashui.ui.Text.at(nodes("#rayde-account-name")[0]).text()=="updated","External sign-in did not refresh the header username");
			signOut();check(approved!=null&&requests.length==2,"Sign-out bypassed unsaved-file guard");approved();settle();check(requests.length==3&&requests[2].op=="account.signout"&&control.busy.get(),"Sign-out request did not start asynchronously");
			signOut();check(requests.length==3,"Repeated click duplicated sign-out");click("#rayde-account-trigger");
			requests[2].future.reject(new rayde.workspace.session.SessionClient.SessionFailure("account","Could not sign out"));settle();check(!control.busy.get()&&messages[0]=="Could not sign out"&&control.user.get().login=="updated","Failed sign-out lost account state or message");
			click("#rayde-account-trigger");click("#rayde-account-retry");check(requests[3].op=="account.status","Account failure has no retry");requests[3].future.resolve({result:{user:{login:"updated"}}});settle();
			signOut();approved();settle();check(control.operation=="account.signout","Sign-out operation was replaced");requests[4].future.resolve(haxe.Json.parse('{"result":{}}'));settle();check(control.user.get()==null&&!control.busy.get()&&control.failure.get()=="","Signed-out header retained account name or an error: "+control.failure.get());
			click();check(requests[5].op=="account.signin","Signed-out header has no sign-in action");requests[5].future.resolve({result:{user:{login:"alice"}}});settle();check(control.user.get().login=="alice","Popup sign-in did not update header");
		} catch(error:Dynamic){stop();tree.dispose();throw error;}
		listener({ev:"account.changed",user:null});settle();control.request("account.signin");var abandoned=requests[requests.length-1].future;click();check(control.cancelling.get()&&requests[requests.length-1].op=="account.cancel-signin","Pending sign-in has no Cancel action");abandoned.reject("cancelled");settle();check(!control.busy.get()&&control.failure.get()=="","Cancelled sign-in left an error or a disabled button");
		control.request("account.signin");stop();check(unsubscribed&&control.gone&&requests[requests.length-1].op=="account.cancel-signin","Closed header retained its account listener or pending sign-in");listener({ev:"account.changed",user:{login:"other"}});check(control.user.get()==null,"Disposed header accepted account updates");tree.dispose();
	}
}
