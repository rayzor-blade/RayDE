import * as Y from 'yjs';
import {samplePreset} from './preset.js';

/** The public baseline is immutable; each browser edits it with its own replica identity. */
export class DemoSource {
  static async read(bytes,expected) {
    if(!(bytes instanceof Uint8Array)||bytes.length>3*1024*1024)throw Error('The demo source is invalid.');
    const release=Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes)),byte=>byte.toString(16).padStart(2,'0')).join('');
    if(expected!==undefined&&release!==expected)throw Error('The demo source release changed.');
    const preset=samplePreset(JSON.parse(new TextDecoder('utf-8',{fatal:true}).decode(bytes)));
    if(preset.root!=='/work/pocket-studio'||preset.project!=='pocket-studio/build.hxml'||preset.entries.some(entry=>entry.path.split('/').some(part=>['.git','.haxelib','.rayde','.rayzor','.rayde-session'].includes(part))))throw Error('The demo source is invalid.');
    const source=new DemoSource();source.release=release;source.preset=preset;
    source.files=new Map(preset.entries.filter(entry=>!entry.directory).map(entry=>[entry.path.slice(preset.root.length+1),entry.data]));
    return source;
  }
  graph(path) {
    const encoded=this.files.get(path);if(encoded===undefined)return null;
    let text;
    try{text=new TextDecoder('utf-8',{fatal:true,ignoreBOM:true}).decode(Uint8Array.from(atob(encoded),char=>char.charCodeAt(0)));}
    catch{return null;}
    const seed=new Y.Doc();seed.clientID=0;
    try {seed.getText('text').insert(0,text);return Y.encodeStateAsUpdate(seed);}
    finally {seed.destroy();}
  }
}
