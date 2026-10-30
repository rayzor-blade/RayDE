use super::*;
use crate::{
    registry::{Cell, Record},
};
use rayde_sandbox as sb;
use axum::extract::ws::{Message, WebSocket};
use std::{sync::Arc, time::Duration};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};

// Guest-local transport authentication is separate from the credential held by the gateway.
pub(crate) const GUEST_TOKEN: &str = "rayde-local-transport";
const MAX_MESSAGE: usize = rayde_session::session::MAX_MESSAGE;

/// The guest program that carries the session's framed stream on its stdio.
fn bridge() -> sb::Command {
    sb::Command {
        program: "/opt/rayde-session".into(),
        args: ["bridge", "--port", "7071"].map(String::from).to_vec(),
        env: Default::default(),
    }
}
async fn read_frame(reader: &mut (impl AsyncRead + Unpin)) -> Result<String> {
    let length = reader.read_u32().await? as usize;
    if length > MAX_MESSAGE {
        return Err(unavailable());
    }
    let mut bytes = vec![0; length];
    reader.read_exact(&mut bytes).await?;
    String::from_utf8(bytes).map_err(|_| unavailable())
}

pub(crate) async fn probe(backend: &impl sb::SandboxProvider, sandbox: &str, persistent_disks: bool) -> Result<serde_json::Value> {
    let work = async {
        let sb::Process { stdin: mut input, stdout: mut output, exit } = backend.spawn(sandbox, bridge()).await?;
        input
            .write_all(&rayde_session::framing::frame(
                &serde_json::json!({"id":1,"op":"hello","token":GUEST_TOKEN}).to_string(),
            ))
            .await?;
        let response: serde_json::Value =
            serde_json::from_str(&read_frame(&mut output).await?).map_err(|_| unavailable())?;
        drop(input);
        if exit.await != Ok(0) {
            return Err(unavailable());
        }
        if response["ok"] != true || response["root"] != "/workspace/project" {
            return Err(unavailable());
        }
        if persistent_disks && response["privateJournals"] != 1 {return Err(unavailable());}
        identity(&response)
    };
    tokio::time::timeout(Duration::from_secs(5), work)
        .await
        .map_err(|_| unavailable())?
}

pub(crate) fn identity(response: &serde_json::Value) -> Result<serde_json::Value> {
    let identity = &response["cacheIdentity"];
    if identity["version"] != 1
        || ["authority", "workspace"].iter().any(|field| {
            !identity[*field]
                .as_str()
                .is_some_and(|value| !value.is_empty() && value.len() <= 128)
        })
    {
        return Err(unavailable());
    }
    Ok(identity.clone())
}

pub(crate) async fn relay<P: sb::SandboxProvider + 'static>(mut socket: WebSocket, backend: Arc<P>, cell: Arc<Cell>, record: Record) {
    let mut closed = cell.closed.subscribe();
    let work=async {
        let first=tokio::select! {
            _=closed.changed()=>return Err(unavailable()),
            first=tokio::time::timeout(Duration::from_secs(10),socket.recv())=>first.map_err(|_|unavailable())?.ok_or_else(unavailable)?.map_err(|_|unavailable())?,
        };
        let Message::Text(first)=first else {return Err(invalid());};
        if first.len()>16*1024 {return Err(invalid());}
        let mut hello:serde_json::Value=serde_json::from_str(&first).map_err(|_|invalid())?;
        if hello["op"]!="hello"||!hello["token"].as_str().is_some_and(|token|matches_secret(token,&record.token)) {return Err(invalid());}
        {
            let current=cell.record.try_lock().map_err(|_|unavailable())?;
            if current.phase!="ready"||!matches_secret(&current.token,&record.token) {return Err(unavailable());}
        }
        hello["token"]=serde_json::json!(GUEST_TOKEN);
        let sb::Process { stdin: mut input, stdout: mut output, exit } = backend.spawn(&record.sandbox, bridge()).await?;
        let mut frames=rayde_session::framing::Frames::default();let mut buffer=vec![0u8;64*1024];let mut first_response=true;
        let conversation=async {
            input.write_all(&rayde_session::framing::frame(&hello.to_string())).await?;
            loop {tokio::select! {
                message=socket.recv()=>{
                    match message {
                        Some(Ok(Message::Text(text)))=>{
                            if text.len()>MAX_MESSAGE {return Err(invalid());}
                            let mut value:serde_json::Value=serde_json::from_str(&text).map_err(|_|invalid())?;
                            let text=if value["op"]=="hello" {
                                if !value["token"].as_str().is_some_and(|token|matches_secret(token,&record.token)) {return Err(invalid());}
                                value["token"]=serde_json::json!(GUEST_TOKEN);value.to_string()
                            } else {text};
                            input.write_all(&rayde_session::framing::frame(&text)).await?;
                        }
                        Some(Ok(Message::Ping(_)|Message::Pong(_)))=>{},
                        _=>break,
                    }
                }
                count=output.read(&mut buffer)=>{
                    let count=count?;if count==0 {break;}
                    for response in frames.push(&buffer[..count]).map_err(|_|unavailable())? {
                        if first_response {let hello=serde_json::from_str(&response).map_err(|_|unavailable())?;if Some(identity(&hello)?)!=record.identity {return Err(unavailable());}first_response=false;}
                        socket.send(Message::Text(response)).await.map_err(|_|unavailable())?;
                    }
                }
            }}
            Ok::<(),Failure>(())
        };
        tokio::select! {_=closed.changed()=>{},_=conversation=>{}}
        drop(input);drop(output);
        // Dropping the exit receiver ends the process, so a bridge that does not leave within two seconds is killed.
        let _=tokio::time::timeout(Duration::from_secs(2),exit).await;
        Ok::<(),Failure>(())
    }.await;
    let _ = work;
    let _ = socket.close().await;
}
