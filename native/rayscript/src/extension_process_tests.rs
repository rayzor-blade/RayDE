use super::*;

fn host() -> i32 {
    let name = if cfg!(windows) { "rayde-extension-host.exe" } else { "rayde-extension-host" };
    let binary = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../bin").join(name).canonicalize().expect("Build the native host before its process tests");
    open(&json!({"binary":binary,"extension":"transport-test"}).to_string()).unwrap()
}

fn until(mut done:impl FnMut()->bool) {
    let end = std::time::Instant::now() + Duration::from_secs(8);
    while !done() {
        assert!(std::time::Instant::now() < end,"Extension process test timed out");
        thread::sleep(Duration::from_millis(2));
    }
}

#[test]
fn malformed_and_unterminated_frames_are_bounded() {
    for text in ["bad\n","[]\n","{\"t\":1}\n","{\"t\":\"ready\"}"] {
        assert!(read_line(&mut io::Cursor::new(text)).is_err());
    }
    assert!(read_line(&mut io::Cursor::new(vec![b'x';MAX_MESSAGE+20])).is_err());
    assert_eq!(read_line(&mut io::Cursor::new("{\"t\":\"ready\"}\n")).unwrap().unwrap(),"{\"t\":\"ready\"}");
    for text in ["{\"t\":\"ops\",\"ops\":null}\n", "{\"t\":\"ops\",\"ops\":[[]]}\n", "{\"t\":\"call\",\"args\":null}\n"] {
        assert!(frame(&mut io::Cursor::new(text),true).is_err());
    }
}

#[test]
fn process_reaps_and_releases_its_transport_owners() {
    let handle = host(); let client = client(handle).unwrap();
    until(|| poll(handle).is_some_and(|line| line.contains("ready")));
    assert_ne!(client.pid.load(Ordering::Acquire),std::process::id());
    assert!(!pending(handle));
    close(handle);
    assert!(self::client(handle).is_none());
    until(|| *client.done.0.lock().unwrap());
    assert!(client.child.lock().unwrap().is_none());
    until(|| Arc::strong_count(&client) == 1);
}

#[test]
fn noisy_process_hits_the_output_budget_and_is_reaped() {
    let handle = host(); let client = client(handle).unwrap();
    until(|| poll(handle).is_some_and(|line| line.contains("ready")));
    assert!(send(handle,&json!({"t":"run","name":"flood.rays","source":"for (i in 0...6000) trace('flood');"}).to_string()));
    until(|| status(handle) != 0);
    assert_eq!(status(handle),2);
    {
        let queue = client.output.lock().unwrap();
        assert!(queue.1 <= MAX_QUEUE && queue.0.len() <= MAX_EVENTS);
        assert!(queue.0.back().unwrap().contains("exceeded its limit"));
    }
    close(handle);
    until(|| Arc::strong_count(&client) == 1);
}

#[test]
fn missing_executable_fails_asynchronously_and_does_not_leave_a_host() {
    let handle = open(&json!({"binary":"/missing/rayde-extension-host"}).to_string()).unwrap();
    until(|| status(handle) != 0);
    assert_eq!(status(handle),2);
    assert!(poll(handle).unwrap().contains("\"kind\":\"host\""));
    close(handle);
}
