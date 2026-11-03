import ashui.core.render.Offscreen;
import ashui.css.Css;
import ashui.layout.LayoutTree;
import ashui.layout.Node;
import ashui.reactive.Owner;
import ashui.reactive.Signal;
import rayde.ui.NewProject;
import rayde.ui.CreateRepository;

@:access(rayde.ui.NewProject)
@:access(rayde.ui.CreateRepository)
class CloudProjectChecks {
	static function check(ok:Bool, message:String):Void { if (!ok) throw message; }
	static function main():Void {
		for (dark in [true,false]) for (width in [680,1280]) run(dark,width);
		Sys.println("cloud projects: template-first dialog, retained selection, private repository form, pending sign-in, failure, retry and cancellation in both themes");
	}
	static function run(dark:Bool, width:Int):Void {
		ashui.theme.ThemeState.init(ashui.theme.themes.RestrainedTheme.bundle(), dark ? Dark : Light); rayde.ui.Style.use();
		var tree=new LayoutTree(), stop:Void->Void=null, opened=Signal.make(true), phase=Signal.make(0), form:NewProject=null, repo:CreateRepository=null;
		var ready="";
		var root=Owner.root(tree,cleanup -> {
			stop=cleanup;
			return <div id="rayde" widthPercent={1} heightPercent={1}>
				<if {opened.get()}><if {phase.get()==0}>${form=new NewProject({opened:opened,directory:"/work",cloud:true,onCreate:_ -> throw "Used local file creation"})}
				<else>${repo=new CreateRepository({opened:opened,name:"sample",template:rayde.project.ProjectTemplates.get("ashui"),back:() -> phase.set(0),ready:(id,_) -> {ready=id;opened.set(false);}})}</if></if>
			</div>;
		});
		function settle(frames=8):Void for(_ in 0...frames){Offscreen.advance(.025);Css.setViewport(width,760);Css.update();tree.flush();tree.computeLayout(root.node,width,760);}
		function nodes(selector:String) return Css.query(tree,root.node.id,selector);
		function box(selector:String){var ids=nodes(selector);check(ids.length==1,"Missing "+selector);return tree.getScrolledBounds(new Node(ids[0]));}
		function click(selector:String):Void {var b=box(selector);ashui.input.Pointer.move(tree,b.x+b.width/2,b.y+b.height/2);ashui.input.Pointer.press(tree);ashui.input.Pointer.release(tree);settle();}
		function reply(op:String,value:Dynamic):Void {repo.operation=op;repo.pending=new ash.Future<Dynamic>();repo.pending.resolve({result:value});repo.poll();settle();}
		try {
			settle();check(nodes(".ui-dialog[open]").length==1&&nodes("#rayde-repository-picker").length==0,"New Project opened a repository list");
			check(nodes("#rayde-project-directory").length==0,"Cloud project requested a local folder");
			click("#rayde-project-template-ashui");form.name.set("my-board");click("#rayde-project-create");
			check(form.repository.get().id=="ashui"&&form.name.get()=="my-board","Template selection was lost before repository setup");
			check(nodes("#rayde-create-repository-dialog").length==1&&nodes(".ui-dialog[open]").length==1,"Repository setup did not replace the template modal");
			click("#rayde-create-repository-back");check(form.repository.get()==null&&form.selected.get()=="ashui"&&form.name.get()=="my-board","Back lost the starter or project name");
			phase.set(1);settle();check(repo.privateRepo.get()&&repo.name.get()=="sample","Repository visibility or project name changed");
			var panel=box("#rayde-create-repository-dialog");check(panel.width>300&&panel.x>=0&&panel.x+panel.width<=width+1&&panel.y>=0&&panel.y+panel.height<=761,"Repository dialog exceeds viewport");
			check(nodes("#rayde-create-repository-signin").length==1,"Signed-out repository setup has no sign-in action");
			reply("account.signin",{user:{login:"alice"}});check(repo.account.get().login=="alice"&&repo.name.get()=="sample","Sign-in discarded the form");
			repo.busy.set(true);repo.operation="account.signin";repo.progress.set("Complete sign-in in the GitHub window…");settle();
			check(nodes("#rayde-create-repository-progress").length==1&&!repo.locked(),"Pending sign-in lacks feedback or cancellation");
			repo.pending=new ash.Future<Dynamic>();repo.pending.reject(new rayde.workspace.session.SessionClient.SessionFailure("account","GitHub sign-in was not completed. Try again."));repo.poll();settle();
			check(repo.error.get()=="GitHub sign-in was not completed. Try again.","The dialog displayed an internal exception name instead of the account error");
			repo.busy.set(true);
			repo.operation="account.open";check(repo.locked(),"Repository mutation can be dismissed while pending");
			reply("account.open",{id:"fixture",status:"failed",message:"Compute unavailable"});check(!repo.busy.get()&&repo.error.get()=="Compute unavailable","Provisioning failure did not allow retry");
			reply("account.open",{id:"fixture",status:"ready",project:"build.hxml"});check(ready=="fixture"&&!opened.get(),"Prepared repository did not open");
			settle();check(nodes(".ui-dialog[open]").length==0,"Closed repository dialog retained its modal");
		} catch(failure:Dynamic){stop();tree.dispose();throw failure;}
		stop();tree.dispose();
	}
}
