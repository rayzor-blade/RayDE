//! A pinned public source graph, shared before admission without sharing visitor edits.
use crate::error::{Result,SessionError};
use base64::{Engine,engine::general_purpose::STANDARD as B64};
use serde::Deserialize;
use std::collections::{BTreeMap,BTreeSet};
use yrs::{ClientID,Doc,OffsetKind,Options,ReadTxn,StateVector,Text,Transact};

#[derive(Deserialize)]
struct Bundle {version:u64,root:String,project:String,entries:Vec<Entry>}
#[derive(Deserialize)]
struct Entry {path:String,directory:bool,data:Option<String>}

pub struct DemoSeed {release:String,texts:BTreeMap<String,String>}
fn invalid()->SessionError {SessionError::new("demo-seed","The pinned demo source graph is invalid.")}
impl DemoSeed {
    pub fn parse(bytes:&[u8],release:&str)->Result<Self> {
        if bytes.len()>3*1024*1024 || release.len()!=64 || crate::checkpoint::digest(bytes)!=release {return Err(invalid());}
        let value:Bundle=serde_json::from_slice(bytes).map_err(|_|invalid())?;
        if value.version!=1 || value.root!="/work/pocket-studio" || value.project!="pocket-studio/build.hxml" || value.entries.len()>256 {return Err(invalid());}
        let mut paths=BTreeSet::new();let mut texts=BTreeMap::new();let mut files=BTreeSet::new();let mut total=0;
        for entry in value.entries {
            if !paths.insert(entry.path.clone()) || entry.directory && entry.data.is_some(){return Err(invalid());}
            if entry.path=="/work" || entry.path==value.root {
                if !entry.directory{return Err(invalid());}continue;
            }
            let path=entry.path.strip_prefix(&(value.root.clone()+"/")).ok_or_else(invalid)?;
            if path.is_empty() || path.split('/').any(|part|part.is_empty() || part=="." || part==".." || part.contains(['\\','\0']) || [".git",".haxelib",".rayde",".rayzor",".rayde-session"].contains(&part)) {return Err(invalid());}
            if !entry.directory {
                let bytes=B64.decode(entry.data.as_deref().ok_or_else(invalid)?).map_err(|_|invalid())?;
                total+=bytes.len();if total>2*1024*1024{return Err(invalid());}
                if let Ok(text)=std::str::from_utf8(&bytes){texts.insert(path.to_owned(),text.to_owned());}
                files.insert(path.to_owned());
            }
        }
        if !paths.contains(&value.root) || !texts.contains_key("build.hxml"){return Err(invalid());}
        if files.iter().any(|file| paths.iter().any(|path| path.starts_with(&format!("{}/{file}/",value.root)))) {return Err(invalid());}
        Ok(Self{release:release.into(),texts})
    }
    pub fn release(&self)->&str {&self.release}
    /// Check image preparation before the first visitor process starts; never overwrite live files.
    #[cfg(feature = "server")]
    pub fn verify_files(bytes:&[u8],release:&str,root:&std::path::Path)->std::io::Result<()> {
        Self::parse(bytes,release).map_err(|_|std::io::Error::other("Invalid demo source release."))?;
        let bundle:Bundle=serde_json::from_slice(bytes)?;
        for entry in bundle.entries.into_iter().filter(|entry|!entry.directory) {
            let path=entry.path.strip_prefix(&(bundle.root.clone()+"/")).unwrap();
            let bytes=B64.decode(entry.data.as_deref().unwrap()).map_err(|_|std::io::Error::other("Invalid demo source bytes."))?;
            let mut current=root.to_path_buf();
            for part in path.split('/') {
                current.push(part);
                if std::fs::symlink_metadata(&current)?.file_type().is_symlink() {
                    return Err(std::io::Error::other("The demo image contains a source symlink."));
                }
            }
            let metadata=std::fs::metadata(&current)?;
            if !metadata.is_file() || metadata.len()!=bytes.len() as u64 || std::fs::read(current)?!=bytes {
                return Err(std::io::Error::other("The demo image does not match its source release."));
            }
        }
        Ok(())
    }
    /// Only immutable source uses client zero; live replicas always keep their own writer identity.
    pub fn graph(&self,path:&str)->Option<Vec<u8>> {
        let source=self.texts.get(path)?;
        let doc=Doc::with_options(Options{offset_kind:OffsetKind::Utf16,..Options::with_client_id(ClientID::new(0))});
        doc.get_or_insert_text("text").insert(&mut doc.transact_mut(),0,source);
        Some(doc.transact().encode_state_as_update_v1(&StateVector::default()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_verified_bounded_public_sources_supply_initial_graphs(){
        let make=|path:&str|serde_json::to_vec(&serde_json::json!({"version":1,"root":"/work/pocket-studio","project":"pocket-studio/build.hxml","entries":[
            {"path":"/work/pocket-studio","directory":true},
            {"path":path,"directory":false,"data":B64.encode("-main Main\n")}
        ]})).unwrap();
        let bytes=make("/work/pocket-studio/build.hxml");let release=crate::checkpoint::digest(&bytes);
        let seed=DemoSeed::parse(&bytes,&release).unwrap();
        assert!(seed.graph("build.hxml").is_some());assert!(seed.graph("../build.hxml").is_none());
        assert!(DemoSeed::parse(&bytes,&"0".repeat(64)).is_err());
        for path in ["/outside","/work/pocket-studio/../build.hxml","/work/pocket-studio/.git/config"] {
            let bytes=make(path);assert!(DemoSeed::parse(&bytes,&crate::checkpoint::digest(&bytes)).is_err());
        }
    }
}
