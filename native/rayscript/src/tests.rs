use super::*;

fn wait(runtime: &Runtime, wanted: &str) -> String {
    wait_excluding(runtime, wanted, &[])
}

fn wait_excluding(runtime: &Runtime, wanted: &str, forbidden: &[&str]) -> String {
    let deadline = Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let lines = std::mem::take(&mut *runtime.output.lock().unwrap());
        assert!(
            !lines
                .iter()
                .any(|line| forbidden.iter().any(|text| line.contains(text))),
            "{lines:?}"
        );
        if let Some(line) = lines.into_iter().find(|line| line.contains(wanted)) {
            return line;
        }
        assert!(Instant::now() < deadline, "waiting for {wanted}");
        thread::sleep(std::time::Duration::from_millis(2));
    }
}

fn message(runtime: &Runtime, line: &str) {
    runtime.input.send(Command::Message(line.into())).unwrap();
}

fn stop(runtime: &Runtime) {
    runtime.input.send(Command::Shutdown).unwrap();
    let deadline = Instant::now() + std::time::Duration::from_secs(5);
    while runtime.status.load(Ordering::Acquire) == 0 {
        assert!(Instant::now() < deadline, "runtime shutdown");
        thread::sleep(std::time::Duration::from_millis(2));
    }
    assert_eq!(runtime.status.load(Ordering::Acquire), 1);
}

#[test]
fn close_unmounts_and_collects_without_script_activity() {
    let runtime = Runtime::start(None).unwrap();
    wait(&runtime, "ready");
    message(
        &runtime,
        r#"{"t":"run","name":"cleanup.rays","source":"mount(() -> { onCleanup(() -> trace('released')); return <div>hello</div>; }, 'view');"}"#,
    );
    wait(&runtime, "\"t\":\"ops\"");
    runtime.input.send(Command::CloseView(1)).unwrap();
    wait(&runtime, "released");
    runtime.input.send(Command::Collect).unwrap();
    wait(&runtime, "collected");
    message(&runtime, r#"{"t":"describe"}"#);
    let state = wait(&runtime, "\"t\":\"describe\"");
    assert!(state.contains("\"nodes\":0"), "{state}");
    assert!(state.contains("\"mounts\":[]"), "{state}");
    stop(&runtime);
}

#[test]
fn exception_aborts_fiber_and_other_commands_still_run() {
    let runtime = Runtime::start(None).unwrap();
    wait(&runtime, "ready");
    message(
        &runtime,
        r#"{"t":"run","name":"exception.rays","source":"registerCommand('fail', () -> { throw 'fiber failed'; }); registerCommand('okay', () -> trace('still running'));"}"#,
    );
    wait(&runtime, "registered");
    message(&runtime, r#"{"t":"command","id":"fail"}"#);
    wait(&runtime, "fiber failed");
    message(&runtime, r#"{"t":"command","id":"okay"}"#);
    wait(&runtime, "still running");
    stop(&runtime);
}

#[test]
fn shutdown_does_not_wait_for_script_timer() {
    let runtime = Runtime::start(None).unwrap();
    wait(&runtime, "ready");
    message(
        &runtime,
        r#"{"t":"run","name":"waiting.rays","source":"await sleep(600000); trace('too late');"}"#,
    );
    wait(&runtime, "started");
    stop(&runtime);
}

#[test]
fn closing_a_view_cancels_its_awaiting_handler_before_a_late_reply() {
    let runtime = Runtime::start(None).unwrap();
    wait(&runtime, "ready");
    message(
        &runtime,
        r#"{"t":"module","path":"test","functions":["gate"]}"#,
    );
    message(
        &runtime,
        r#"{"t":"run","name":"await.rays","source":"import test.gate; mount(() -> <button onClick={() -> { await gate(); trace('stale handler'); }}>wait</button>, 'view');"}"#,
    );
    wait(&runtime, "\"t\":\"ops\"");
    message(&runtime, r#"{"t":"event","node":2,"event":"click"}"#);
    let call = wait(&runtime, "\"t\":\"call\"");
    let id: u64 = call
        .split("\"id\":")
        .nth(1)
        .unwrap()
        .split(',')
        .next()
        .unwrap()
        .parse()
        .unwrap();
    runtime.input.send(Command::CloseView(1)).unwrap();
    let collected = wait(&runtime, "collected");
    assert!(collected.contains("\"fibers\":0"), "{collected}");
    message(
        &runtime,
        &format!("{{\"t\":\"resolve\",\"id\":{id},\"value\":null}}"),
    );
    runtime.input.send(Command::Collect).unwrap();
    wait_excluding(&runtime, "collected", &["stale handler"]);
    stop(&runtime);
    let lines = std::mem::take(&mut *runtime.output.lock().unwrap());
    assert!(
        !lines.iter().any(|line| line.contains("stale handler")),
        "{lines:?}"
    );
}
