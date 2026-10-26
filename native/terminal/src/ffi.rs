use super::Session;
use hl_abi::{define_prim,hl_alloc_bytes,vbyte};
use std::{panic::catch_unwind,ptr,sync::{Arc,Mutex,MutexGuard},thread};
fn lock<T>(m:&Mutex<T>)->MutexGuard<'_,T>{m.lock().unwrap_or_else(|e|e.into_inner())}

/// Open sessions by handle; a closed one leaves its slot empty.
enum SessionSlot { Ready(Arc<Session>), Starting, Failed }
static SESSIONS: Mutex<Vec<Option<SessionSlot>>> = Mutex::new(Vec::new());

fn session(handle: i32) -> Option<Arc<Session>> {
    match lock(&SESSIONS).get(handle as usize) {
        Some(Some(SessionSlot::Ready(s))) => Some(s.clone()),
        _ => None,
    }
}

unsafe fn text<'a>(data: *const vbyte, len: i32) -> Option<&'a str> {
    if data.is_null() || len < 0 {
        return None;
    }
    std::str::from_utf8(unsafe { std::slice::from_raw_parts(data, len as usize) }).ok()
}

fn to_vm(out: &[u8]) -> *mut vbyte {
    let dest = unsafe { hl_alloc_bytes(out.len() as i32) };
    if dest.is_null() {
        return ptr::null_mut();
    }
    unsafe { ptr::copy_nonoverlapping(out.as_ptr(), dest, out.len()) };
    dest
}

/// Runs `program` (the user's shell when empty) with `args` (joined by the unit separator, 0x1f; a login shell when empty) in `cwd`.
/// The handle of the session, or -1.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_open(cols: i32, rows: i32, cwd: *const vbyte, cwd_len: i32, program: *const vbyte, program_len: i32, args: *const vbyte, args_len: i32) -> i32 {
    catch_unwind(|| {
        let cwd = unsafe { text(cwd, cwd_len) }.filter(|s| !s.is_empty());
        let program = unsafe { text(program, program_len) }.filter(|s| !s.is_empty()).map(str::to_string).unwrap_or_else(|| {
            std::env::var("SHELL").unwrap_or_else(|_| if cfg!(windows) { "powershell.exe".into() } else { "/bin/sh".into() })
        });
        let args: Vec<String> = match unsafe { text(args, args_len) } {
            Some(a) if !a.is_empty() => a.split('\u{1f}').map(str::to_string).collect(),
            _ if cfg!(windows) => Vec::new(),
            _ => vec!["-l".into()],
        };
        match Session::spawn(&program, &args, cwd, cols.clamp(2, 1000) as u16, rows.clamp(1, 500) as u16) {
            Ok(s) => {
                let mut all = lock(&SESSIONS);
                all.push(Some(SessionSlot::Ready(Arc::new(s))));
                (all.len() - 1) as i32
            }
            Err(_) => -1,
        }
    })
    .unwrap_or(-1)
}
define_prim!(hlp_term_open, term_open, "PiiBiBiBi_i");

fn start_background(cols: u16, rows: u16, cwd: Option<String>, program: String, args: Vec<String>) -> i32 {
    let handle = {
        let mut all = lock(&SESSIONS);
        all.push(Some(SessionSlot::Starting));
        (all.len() - 1) as i32
    };
    let started = thread::Builder::new().name("terminal-start".into()).spawn(move || {
        let result = catch_unwind(|| Session::spawn(&program, &args, cwd.as_deref(), cols, rows))
            .unwrap_or_else(|_| Err("Terminal startup panicked".into()));
        let mut all = lock(&SESSIONS);
        if !matches!(all.get(handle as usize), Some(Some(SessionSlot::Starting))) {
            drop(all);
            if let Ok(session) = result { session.kill(); }
            return;
        }
        all[handle as usize] = Some(match result {
            Ok(session) => SessionSlot::Ready(Arc::new(session)),
            Err(_) => SessionSlot::Failed,
        });
    });
    if started.is_err() { lock(&SESSIONS)[handle as usize] = None; return -1; }
    handle
}

/// Copies VM strings before a worker creates the PTY and process. Closing its handle cancels publication.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_open_background(cols: i32, rows: i32, cwd: *const vbyte, cwd_len: i32, program: *const vbyte, program_len: i32, args: *const vbyte, args_len: i32) -> i32 {
    catch_unwind(|| {
        let cwd = unsafe { text(cwd, cwd_len) }.filter(|s| !s.is_empty()).map(str::to_string);
        let program = unsafe { text(program, program_len) }.filter(|s| !s.is_empty()).map(str::to_string)
            .unwrap_or_else(|| std::env::var("SHELL").unwrap_or_else(|_| if cfg!(windows) { "powershell.exe".into() } else { "/bin/sh".into() }));
        let args = match unsafe { text(args, args_len) } {
            Some(a) if !a.is_empty() => a.split('\u{1f}').map(str::to_string).collect(),
            _ if cfg!(windows) => Vec::new(),
            _ => vec!["-l".into()],
        };
        start_background(cols.clamp(2, 1000) as u16, rows.clamp(1, 500) as u16, cwd, program, args)
    }).unwrap_or(-1)
}
define_prim!(hlp_term_open_background, term_open_background, "PiiBiBiBi_i");

/// 0 while creating the process, 1 ready, -1 failed, -2 closed.
#[unsafe(no_mangle)]
pub extern "C" fn term_state(handle: i32) -> i32 {
    match lock(&SESSIONS).get(handle as usize) {
        Some(Some(SessionSlot::Starting)) => 0,
        Some(Some(SessionSlot::Ready(_))) => 1,
        Some(Some(SessionSlot::Failed)) => -1,
        _ => -2,
    }
}
define_prim!(hlp_term_state, term_state, "Pi_i");

/// Types `len` bytes at `data` into the session. 1 when written.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_write(handle: i32, data: *const vbyte, len: i32) -> i32 {
    catch_unwind(|| match session(handle) {
        Some(s) if !data.is_null() && len > 0 => s.write(unsafe { std::slice::from_raw_parts(data, len as usize) }) as i32,
        _ => 0,
    })
    .unwrap_or(0)
}
define_prim!(hlp_term_write, term_write, "PiBi_i");

#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_resize(handle: i32, cols: i32, rows: i32) -> i32 {
    catch_unwind(|| match session(handle) {
        Some(s) => {
            s.resize(cols.clamp(2, 1000) as u16, rows.clamp(1, 500) as u16);
            1
        }
        None => 0,
    })
    .unwrap_or(0)
}
define_prim!(hlp_term_resize, term_resize, "Piii_i");

#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_revision(handle: i32) -> i32 {
    catch_unwind(|| session(handle).map_or(0, |s| s.revision())).unwrap_or(0)
}
define_prim!(hlp_term_revision, term_revision, "Pi_i");

/// -1 while the program runs, else its exit code; -3 for no such session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_exit(handle: i32) -> i32 {
    catch_unwind(|| session(handle).map_or_else(|| match term_state(handle) { 0 => -1, -1 => 127, _ => -3 }, |s| s.exit_code())).unwrap_or(-3)
}
define_prim!(hlp_term_exit, term_exit, "Pi_i");

/// The screen's state, sixteen bytes (see `Session::info`).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_info(handle: i32) -> *mut vbyte {
    catch_unwind(|| session(handle).map_or(ptr::null_mut(), |s| to_vm(&s.info()))).unwrap_or(ptr::null_mut())
}
define_prim!(hlp_term_info, term_info, "Pi_B");

/// A byte a row saying which rows changed since this was last asked.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_dirty(handle: i32) -> *mut vbyte {
    catch_unwind(|| session(handle).map_or(ptr::null_mut(), |s| to_vm(&s.dirty()))).unwrap_or(ptr::null_mut())
}
define_prim!(hlp_term_dirty, term_dirty, "Pi_B");

/// A row as runs (see `Session::row`), led by its length in four little-endian bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_row(handle: i32, row: i32) -> *mut vbyte {
    catch_unwind(|| {
        let Some(s) = session(handle) else { return ptr::null_mut() };
        let body = s.row(row.max(0) as u16);
        let mut out = (body.len() as u32).to_le_bytes().to_vec();
        out.extend_from_slice(&body);
        to_vm(&out)
    })
    .unwrap_or(ptr::null_mut())
}
define_prim!(hlp_term_row, term_row, "Pii_B");

/// Shows the screen `lines` back in its history; the offset it got, which the history's length bounds.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_scrollback(handle: i32, lines: i32) -> i32 {
    catch_unwind(|| session(handle).map_or(0, |s| s.set_scrollback(lines.max(0) as usize) as i32)).unwrap_or(0)
}
define_prim!(hlp_term_scrollback, term_scrollback, "Pii_i");

/// The text between two cells, led by its length in four little-endian bytes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_text(handle: i32, row1: i32, col1: i32, row2: i32, col2: i32) -> *mut vbyte {
    catch_unwind(|| {
        let Some(s) = session(handle) else { return ptr::null_mut() };
        let body = s.text(row1.max(0) as u16, col1.max(0) as u16, row2.max(0) as u16, col2.max(0) as u16);
        let mut out = (body.len() as u32).to_le_bytes().to_vec();
        out.extend_from_slice(body.as_bytes());
        to_vm(&out)
    })
    .unwrap_or(ptr::null_mut())
}
define_prim!(hlp_term_text, term_text, "Piiiii_B");

/// Has the next `term_dirty` report every row. 1 when there is such a session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_invalidate(handle: i32) -> i32 {
    catch_unwind(|| match session(handle) {
        Some(s) => {
            s.invalidate();
            1
        }
        None => 0,
    })
    .unwrap_or(0)
}
define_prim!(hlp_term_invalidate, term_invalidate, "Pi_i");

/// Ends the program and frees the session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_close(handle: i32) -> i32 {
    catch_unwind(|| {
        let taken = lock(&SESSIONS).get_mut(handle as usize).and_then(|s| s.take());
        match taken {
            Some(SessionSlot::Ready(s)) => { s.kill(); 1 }
            Some(SessionSlot::Starting | SessionSlot::Failed) => 1,
            None => 0,
        }
    })
    .unwrap_or(0)
}
define_prim!(hlp_term_close, term_close, "Pi_i");

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{Duration, Instant};

    #[test]
    fn background_start_failure_and_cancellation() {
        let handle = start_background(40, 6, None, "/bin/sh".into(), vec!["-c".into(), "printf ready; read value".into()]);
        assert!(handle >= 0);
        let end = Instant::now() + Duration::from_secs(3);
        while term_state(handle) == 0 && Instant::now() < end { thread::sleep(Duration::from_millis(5)); }
        assert_eq!(term_state(handle), 1);
        let s = session(handle).expect("a started session");
        assert!(wait(&s, |text| text.contains("ready")).contains("ready"));
        unsafe { term_close(handle); }
        assert_eq!(term_state(handle), -2);

        let failed = start_background(40, 6, None, "/rayde-no-such-shell".into(), vec![]);
        let end = Instant::now() + Duration::from_secs(3);
        while term_state(failed) == 0 && Instant::now() < end { thread::sleep(Duration::from_millis(5)); }
        assert_eq!(term_state(failed), -1);
        assert_eq!(unsafe { term_exit(failed) }, 127);
        unsafe { term_close(failed); }

        let cancelled = start_background(40, 6, None, "/bin/sh".into(), vec!["-c".into(), "read value".into()]);
        unsafe { term_close(cancelled); }
        thread::sleep(Duration::from_millis(100));
        assert_eq!(term_state(cancelled), -2);
        assert!(session(cancelled).is_none(), "a cancelled worker must not publish its process");
    }

    /// Waits until `done` holds of the screen's text, or three seconds pass.
    fn wait(s: &Session, done: impl Fn(&str) -> bool) -> String {
        let end = Instant::now() + Duration::from_secs(3);
        loop {
            let info=s.info();let rows=u16::from_le_bytes([info[0],info[1]]);let cols=u16::from_le_bytes([info[2],info[3]]);
            let text = s.text(0, 0, rows - 1, cols);
            if done(&text) || Instant::now() > end {
                return text;
            }
            thread::sleep(Duration::from_millis(20));
        }
    }

    fn sh(script: &str) -> Session {
        Session::spawn("/bin/sh", &["-c".into(), script.into()], None, 40, 6).expect("a shell")
    }

    #[test]
    fn what_a_program_prints_is_on_the_screen() {
        let s = sh("printf 'hello\\nworld\\n'; sleep 1");
        let text = wait(&s, |t| t.contains("world"));
        assert!(text.contains("hello") && text.contains("world"), "{text:?}");
        s.kill();
    }

    #[test]
    fn colours_and_attributes_come_as_runs() {
        let s = sh("printf '\\033[1;31mred\\033[0m plain \\033[48;2;1;2;3mbg\\033[0m'; sleep 1");
        wait(&s, |t| t.contains("plain"));
        let row = s.row(0);
        // First run: columns 0 to 3, bold, palette colour 1 (red), default background, the text "red".
        assert_eq!(&row[0..4], &[0, 0, 3, 0]);
        assert_eq!(row[4], 1, "bold");
        assert_eq!(u32::from_le_bytes(row[5..9].try_into().unwrap()), (1 << 24) | 1);
        assert_eq!(&row[15..18], b"red");
        let rest = String::from_utf8_lossy(&row);
        assert!(rest.contains("plain") && rest.contains("bg"), "{rest:?}");
        s.kill();
    }

    #[test]
    fn typing_reaches_the_program_and_its_exit_is_known() {
        let s = Session::spawn("/bin/sh", &["-c".into(), "read x; printf \"got:%s\\n\" $x".into()], None, 40, 6).expect("a shell");
        assert_eq!(s.exit_code(), -1);
        assert!(s.write(b"abc\n"));
        let text = wait(&s, |t| t.contains("got:abc"));
        assert!(text.contains("got:abc"), "{text:?}");
        let end = Instant::now() + Duration::from_secs(3);
        while s.exit_code() == -1 && Instant::now() < end {
            thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(s.exit_code(), 0);
    }

    #[test]
    fn only_changed_rows_are_dirty() {
        let s = sh("printf 'one\\n'; sleep 0.3; printf 'two\\n'; sleep 1");
        wait(&s, |t| t.contains("one"));
        let first = s.dirty();
        assert_eq!(first.len(), 6);
        assert!(first[0] == 1, "the first look sees every row as new");
        wait(&s, |t| t.contains("two"));
        let second = s.dirty();
        assert_eq!(second[0], 0, "row 0 did not change");
        assert_eq!(second[1], 1, "row 1 did");
        s.kill();
    }

    #[test]
    fn a_program_that_asks_where_the_cursor_is_is_told() {
        let s = sh("printf '\\033[6n'; IFS=R read -r -d R reply; printf \"reply:%s\" \"$reply\" | cat -v; sleep 1");
        let text = wait(&s, |t| t.contains("reply:"));
        assert!(text.contains("reply:^[[1;1"), "{text:?}");
        s.kill();
    }

    #[test]
    fn resizing_changes_the_screen() {
        let s = sh("sleep 1");
        s.resize(20, 4);
        let info = s.info();
        assert_eq!(u16::from_le_bytes([info[0], info[1]]), 4);
        assert_eq!(u16::from_le_bytes([info[2], info[3]]), 20);
        s.kill();
    }
}
