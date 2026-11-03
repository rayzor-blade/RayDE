package rayde.ui;

import ashui.components.Button;
import ashui.components.Icon;
import ashui.components.Progress;
import ashui.layout.Element;
import ashui.reactive.Signal;
import ashui.ui.Component;
import rayde.sync.ResourceUsage.ResourceState;
import rayde.sync.ResourceUsage.ResourceSample;

typedef WorkspaceResourcesProps = {state:Signal<ResourceState>, onRefresh:Void->Void};

/** Usage belongs to the current VM; cloud snapshot storage is reported separately. */
class WorkspaceResources extends Component<WorkspaceResourcesProps> {
	function render():Element
		return <div id="rayde-workspace-resources" class="rayde-sync-card rayde-sync-section">
			<div class="flex flex-row items-center gap-2">
				<text class="rayde-sync-title flex-1">Workspace resources</text>
				<button id="rayde-resources-refresh" variant={Ghost} size={Icon} disabled={props.state.get().loading} onClick={_ -> props.onRefresh()}>
					<if {props.state.get().loading}><icon document={Icons.LOADER_4_LINE} class="size-3.5 animate-spin"/><else><icon document={Icons.REFRESH_LINE} class="size-3.5"/></if>
				</button>
			</div>
			<for {state in [props.state.get()]}>
				<if {state.sample != null}>${measurements(state.sample)}</if>
				<if {state.message != ""}><text id="rayde-resources-message" class="rayde-sync-muted">${state.message}</text>
				<else><if {state.sample == null}><text class="rayde-sync-muted">Loading resource usage…</text><else><text class="rayde-sync-muted">${state.loading ? "Refreshing…" : "Updates every 5 seconds while this panel is open."}</text></if></if>
			</for>
		</div>;
	function measurements(s:ResourceSample):Element
		return <div class="rayde-sync-section rayde-resources-meters">
			${row("CPU",s.cpuPercent==null ? "Unavailable" : decimal(s.cpuPercent)+"%",s.cpuLimit==null ? "" : decimal(s.cpuLimit)+" vCPU","cpu")}
			${row("Memory",bytes(s.memoryBytes),limit(s.memoryLimitBytes),"memory")}
			<if {s.memoryBytes!=null && s.memoryLimitBytes!=null && s.memoryLimitBytes>0}><progress size={Sm} value={Math.min(100,s.memoryBytes/s.memoryLimitBytes*100)} max={100}/></if>
			${row("Workspace disk",bytes(s.storageBytes),limit(s.storageLimitBytes),"storage")}
			<if {s.storageBytes!=null && s.storageLimitBytes!=null && s.storageLimitBytes>0}><progress size={Sm} value={Math.min(100,s.storageBytes/s.storageLimitBytes*100)} max={100}/></if>
			${row("VM uptime",duration(s.uptimeSeconds),s.durationLimitSeconds==null || s.durationLimitSeconds<=0 ? "" : duration(s.durationLimitSeconds)+" limit","uptime")}
		</div>;
	function row(label:String,value:String,limit:String,id:String):Element
		return <div id={"rayde-resources-"+id} class="rayde-resource-row"><text class="rayde-sync-muted">${label}</text><div class="rayde-resource-values"><text>${value}</text><if {limit!=""}><text class="rayde-sync-muted">${limit}</text></if></div></div>;
	static function decimal(value:Float):String return Std.string(Math.round(value*10)/10);
	static function limit(value:Null<Float>):String return value==null ? "" : "of "+bytes(value);
	static function bytes(value:Null<Float>):String {
		if(value==null)return "Unavailable";
		return value>=1073741824 ? decimal(value/1073741824)+" GiB" : value>=1048576 ? decimal(value/1048576)+" MiB" : value>=1024 ? decimal(value/1024)+" KiB" : Std.int(value)+" B";
	}
	static function duration(value:Null<Float>):String {
		if(value==null)return "Unavailable";
		var minutes=Std.int(value/60);
		return minutes>=60 ? Std.int(minutes/60)+"h "+minutes%60+"m" : minutes>0 ? minutes+"m" : Std.int(value)+"s";
	}
}
