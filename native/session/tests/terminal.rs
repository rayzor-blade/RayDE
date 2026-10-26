mod support;
use base64::{Engine, engine::general_purpose::STANDARD as B64};
use serde_json::{Value, json};
use std::time::Duration;
use support::{Client, server};

async fn screen(client: &mut Client, tid: u64, needle: &str) -> Value {
    for _ in 0..100 {
        let update = client.event("term.update").await;
        let text = update["rows"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(|r| r["text"].as_str())
            .collect::<Vec<_>>()
            .join("\n");
        client.request(json!({"op":"term.ack","tid":tid})).await;
        if text.contains(needle) {
            return update;
        }
    }
    panic!("Missing terminal output: {needle}")
}

#[cfg(unix)]
#[tokio::test]
async fn real_pty_input_colours_resize_and_connection_ownership() {
    let dir = tempfile::tempdir().unwrap();
    let running = server(dir.path(), true).await;
    let mut client = Client::connect(&running).await;
    assert_eq!(
        client
            .request(json!({"op":"term.open","key":"early"}))
            .await["code"],
        "unauthorised"
    );
    let hello = client.request(json!({"op":"hello","token":"secret"})).await;
    assert_eq!(hello["terminal"], true);
    assert!(hello["terminalProfiles"].as_array().unwrap().len() > 0);
    let opened=client.request(json!({"op":"term.open","key":"test","program":"/bin/sh","args":["-c",r#"test -t 0 && printf '\033[31mPTY-ready\033[0m\n'; read value; stty size; printf 'got:%s\n' "$value"; sleep 5"#],"cols":80,"rows":12})).await;
    let tid = opened["tid"].as_u64().expect("PTY opened");
    let update = screen(&mut client, tid, "PTY-ready").await;
    assert!(
        update["rows"].as_array().unwrap().iter().any(|r| {
            let bytes = B64.decode(r["runs"].as_str().unwrap()).unwrap();
            bytes.windows(4).any(|w| w == [1, 0, 0, 1])
        }),
        "ANSI palette red remains in packed runs"
    );
    let mut other = Client::hello(&running).await;
    assert_eq!(
        other
            .request(json!({"op":"term.write","tid":tid,"data":"wrong\n"}))
            .await["code"],
        "not-found"
    );
    assert_eq!(
        client
            .request(json!({"op":"term.resize","tid":tid,"cols":101,"rows":19}))
            .await["ok"],
        true
    );
    assert_eq!(
        client
            .request(json!({"op":"term.write","tid":tid,"data":"hello🙂\n"}))
            .await["ok"],
        true
    );
    let update = screen(&mut client, tid, "got:hello🙂").await;
    let info = B64.decode(update["info"].as_str().unwrap()).unwrap();
    assert_eq!(u16::from_le_bytes([info[0], info[1]]), 19);
    assert_eq!(u16::from_le_bytes([info[2], info[3]]), 101);
    assert_eq!(
        client.request(json!({"op":"fs.stat","path":""})).await["ok"],
        true
    );
    assert_eq!(
        client.request(json!({"op":"term.close","tid":tid})).await["ok"],
        true
    );
    assert_eq!(
        client
            .request(json!({"op":"term.write","tid":tid,"data":"late"}))
            .await["code"],
        "not-found"
    );
    drop(other);
    drop(client);
    running.shutdown().await;
}

#[tokio::test]
async fn no_exec_and_terminal_limits_fail_without_breaking_the_session() {
    let dir = tempfile::tempdir().unwrap();
    let running = server(dir.path(), false).await;
    let mut client = Client::hello(&running).await;
    assert_eq!(
        client
            .request(json!({"op":"term.open","key":"denied"}))
            .await["code"],
        "no-exec"
    );
    assert_eq!(
        client.request(json!({"op":"fs.list","path":""})).await["ok"],
        true
    );
    drop(client);
    running.shutdown().await;
    let running = server(dir.path(), true).await;
    let mut client = Client::hello(&running).await;
    assert_eq!(
        client
            .request(json!({"op":"term.open","key":"bad","cols":10000}))
            .await["code"],
        "bad-request"
    );
    assert_eq!(
        client
            .request(json!({"op":"term.open","key":"outside","cwd":"../"}))
            .await["code"],
        "outside"
    );
    let result = client
        .request(json!({"op":"term.open","key":"missing","program":"/rayde-no-such-shell"}))
        .await;
    assert_eq!(result["ok"], true);
    assert_eq!(client.event("term.failed").await["key"], "missing");
    assert_eq!(
        client.request(json!({"op":"fs.list","path":""})).await["ok"],
        true
    );
    drop(client);
    running.shutdown().await;
}

#[cfg(unix)]
#[tokio::test]
async fn screen_backpressure_visibility_and_disconnect_cleanup() {
    let dir = tempfile::tempdir().unwrap();
    let running = server(dir.path(), true).await;
    let mut client = Client::hello(&running).await;
    let marker = dir.path().join("child.pid");
    let opened=client.request(json!({"op":"term.open","key":"busy","program":"/bin/sh","args":["-c","echo $$ > child.pid; while :; do printf 'busy\\n'; sleep 0.02; done"],"cols":60,"rows":8})).await;
    let tid = opened["tid"].as_u64().unwrap();
    client.event("term.update").await;
    assert!(
        tokio::time::timeout(Duration::from_millis(150), client.event("term.update"))
            .await
            .is_err(),
        "An unacknowledged screen must coalesce further output"
    );
    assert_eq!(
        client
            .request(json!({"op":"term.visible","tid":tid,"visible":false}))
            .await["ok"],
        true
    );
    client.request(json!({"op":"term.ack","tid":tid})).await;
    assert!(
        tokio::time::timeout(Duration::from_millis(100), client.event("term.update"))
            .await
            .is_err(),
        "Hidden screens must not stream patches"
    );
    client
        .request(json!({"op":"term.visible","tid":tid,"visible":true}))
        .await;
    screen(&mut client, tid, "busy").await;
    let pid: i32 = std::fs::read_to_string(marker)
        .unwrap()
        .trim()
        .parse()
        .unwrap();
    client.close().await;
    drop(client);
    support::until(|| unsafe { libc::kill(pid, 0) } == -1).await;
    running.shutdown().await;
}

#[cfg(unix)]
#[tokio::test]
async fn session_environment_reaches_processes_and_terminals_with_explicit_process_overrides() {
    use rayde_session::server::{Options, start};
    let dir = tempfile::tempdir().unwrap();
    let mut options = Options::new(dir.path());
    options.exec = true;
    options.token = Some("secret".into());
    options.state_root = Some(dir.path().join(".state"));
    options
        .environment
        .insert("RAYDE_SESSION_ENV_TEST".into(), "configured".into());
    let running = start(options).await.unwrap();
    let mut client = Client::hello(&running).await;
    let process=client.request(json!({"op":"proc.spawn","command":"/bin/sh","args":["-c","printf '%s' \"$RAYDE_SESSION_ENV_TEST\""],"env":{"RAYDE_SESSION_ENV_TEST":"override"}})).await;
    assert_eq!(process["ok"], true);
    let event = client.event("proc.out").await;
    assert_eq!(
        B64.decode(event["data"].as_str().unwrap()).unwrap(),
        b"override"
    );
    let opened=client.request(json!({"op":"term.open","key":"environment","program":"/bin/sh","args":["-c","printf 'env:%s\\n' \"$RAYDE_SESSION_ENV_TEST\"; sleep 1"]})).await;
    screen(
        &mut client,
        opened["tid"].as_u64().unwrap(),
        "env:configured",
    )
    .await;
    client.close().await;
    drop(client);
    running.shutdown().await;
}
