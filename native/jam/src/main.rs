//! JSON-lines driver for exercising the native Jam client across machines.
use rayde_jam::{
    document::{Document, Patch},
    transport::{Config, Session},
};
use serde_json::{Value, json};
use std::{
    io::{BufRead, Write},
    sync::mpsc,
    time::Duration,
};

fn emit(value: Value) {
    println!("{value}");
    let _ = std::io::stdout().flush();
}
fn main() {
    if std::env::args().nth(1).as_deref() != Some("--stdio") {
        eprintln!(
            "Use --stdio with JSON-lines start/edit/undo/presence/pause/snapshot/close commands."
        );
        std::process::exit(2);
    }
    if let Err(error) = run() {
        emit(json!({"t":"failed","message":error}));
        std::process::exit(1);
    }
}
fn run() -> Result<(), String> {
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else {
                break;
            };
            if tx.send(line).is_err() {
                return;
            }
        }
    });
    let first: Value =
        serde_json::from_str(&rx.recv().map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    let host = first["host"].as_bool().unwrap_or(false);
    let restore = first["restore"].as_bool().unwrap_or(false);
    let mut doc = Document::new(if host && !restore {
        first["text"].as_str().unwrap_or("")
    } else {
        ""
    })?;
    let session = Session::start(
        Config {
            host,
            invite: first["invite"].as_str().unwrap_or("").into(),
            name: first["name"].as_str().unwrap_or("Peer").into(),
            file: first["file"].as_str().unwrap_or("Main.hx").into(),
            state: doc.state(),
            document_id: if host && !restore {
                doc.id()
            } else {
                String::new()
            },
            recovery: first["recovery"].as_str().unwrap_or("").into(),
            restore,
        },
        None,
    )?;
    let mut serial = 0u64;
    let publish = |update: String, serial: &mut u64| -> Result<(), String> {
        *serial += 1;
        if session.send(json!({"t":"sync","id":serial,"update":update})) {
            Ok(())
        } else {
            Err("Jam send failed".into())
        }
    };
    loop {
        for message in session.poll() {
            match message["t"].as_str() {
                Some("restored") => {
                    doc.apply(message["state"].as_str().ok_or("Missing recovery state")?)?;
                    emit(
                        json!({"t":"restored","text":doc.text(),"document_id":message["document_id"]}),
                    );
                }
                Some("welcome") => {
                    doc.apply(message["state"].as_str().ok_or("Missing state")?)?;
                    publish(
                        doc.diff(message["vector"].as_str().ok_or("Missing vector")?)?,
                        &mut serial,
                    )?;
                    emit(
                        json!({"t":"welcome","text":doc.text(),"document_id":message["document_id"],"durable":message["durable"]}),
                    );
                }
                Some("update") => {
                    doc.apply(message["update"].as_str().ok_or("Missing update")?)?;
                    emit(json!({"t":"text","text":doc.text()}));
                }
                Some("cursor") => {
                    emit(
                        json!({"t":"cursor","caret":doc.resolve(message["caret"].as_str().ok_or("Missing caret")?)?,"anchor":doc.resolve(message["anchor"].as_str().ok_or("Missing anchor")?)?}),
                    );
                }
                Some("failed") => {
                    emit(message);
                    session.close();
                    return Err("Jam connection failed".into());
                }
                _ => emit(message),
            }
        }
        match rx.recv_timeout(Duration::from_millis(5)) {
            Ok(line) => {
                let command: Value = serde_json::from_str(&line).map_err(|e| e.to_string())?;
                match command["op"].as_str() {
                    Some("edit") => {
                        let parts: Vec<Patch> = serde_json::from_value(command["parts"].clone())
                            .map_err(|e| e.to_string())?;
                        publish(
                            doc.edit(command["before"].as_str().ok_or("Missing before")?, &parts)?,
                            &mut serial,
                        )?;
                        emit(json!({"t":"edited","text":doc.text()}));
                    }
                    Some("undo") | Some("redo") => {
                        publish(doc.undo(command["op"] == "redo"), &mut serial)?;
                        emit(json!({"t":"edited","text":doc.text()}));
                    }
                    Some("presence") => {
                        session.send(json!({"t":"presence","caret":doc.position(command["caret"].as_u64().unwrap_or(0) as u32)?,"anchor":doc.position(command["anchor"].as_u64().unwrap_or(0) as u32)?}));
                    }
                    Some("pause") => {
                        session.send(json!({"t":"pause","paused":command["paused"]}));
                    }
                    Some("checkpoint") => {
                        session.send(json!({"t":"checkpoint","id":serial}));
                    }
                    Some("snapshot") => emit(json!({"t":"snapshot","text":doc.text()})),
                    Some("crash") => std::process::exit(86),
                    Some("close") => {
                        shutdown(&session);
                        return Ok(());
                    }
                    _ => return Err("Unknown probe command".into()),
                }
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                shutdown(&session);
                return Ok(());
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
        }
    }
}

fn shutdown(session: &std::sync::Arc<Session>) {
    session.close();
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    while std::sync::Arc::strong_count(session) > 1 && std::time::Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(1));
    }
}
