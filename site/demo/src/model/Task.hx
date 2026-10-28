package model;

/** Immutable task snapshots make reactive updates easy to follow. */
typedef Task = {
    final id:Int;
    final title:String;
    final description:String;
    final lane:String;
    final tag:String;
    final owner:String;
}
