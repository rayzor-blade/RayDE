package rayde.ui.workbench;

import rayde.ext.Manifest;
import rayde.ext.Manifest.ViewDecl;
import rayde.term.Profiles.Profile;
import rayde.term.Terminal;

/** A status item an extension set, as the workbench keeps it. */
typedef ExtensionStatus = {owner:String, id:String, text:String, ?icon:String, ?detail:String, ?detailIcon:String, ?tooltip:String, ?view:String, ?command:String};

/** A part of the layout an extension view takes: its icon in the activity bar, and where its view is drawn. */
typedef Container = {id:String, title:String, icon:ashui.svg.SvgDocument, location:String, view:ViewDecl, extension:Manifest};

/** A terminal that is running, and the profile it was started from. */
typedef Session = {id:Int, group:Int, terminal:Terminal, profile:Profile};
