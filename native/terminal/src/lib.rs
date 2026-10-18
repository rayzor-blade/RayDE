//! A shell on a pseudo-terminal, and the screen it draws, for RayDE's terminal tab.
//!
//! A session runs a program on a PTY. A thread reads what it prints into a
//! `vt100` screen, which keeps the grid, colours, cursor, scrollback and the
//! alternate screen. The VM never sees a cell: it asks which rows changed and
//! fetches those as runs of equally styled text, so a busy terminal costs the
//! VM a few rows a frame and not an object a cell.
use hl_abi::{define_prim, hl_alloc_bytes, vbyte};
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use std::{
    collections::hash_map::DefaultHasher,
    hash::{Hash, Hasher},
    io::{Read, Write},
    panic::catch_unwind,
    ptr,
    sync::{
        atomic::{AtomicI32, AtomicU32, Ordering},
        Arc, Mutex, MutexGuard,
    },
    thread,
};

/// The most scrollback a session keeps, in lines.
const SCROLLBACK: usize = 5000;

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

pub struct Session {
    parser: Arc<Mutex<vt100::Parser>>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    master: Mutex<Box<dyn MasterPty + Send>>,
    child: Mutex<Box<dyn Child + Send + Sync>>,
    /// Changes whenever the screen does, for whoever polls it.
    revision: Arc<AtomicU32>,
    /// -1 while the program runs, then its exit code.
    exit: Arc<AtomicI32>,
    /// A hash of each row as last asked about, to tell which have changed.
    hashes: Mutex<Vec<u64>>,
}

impl Session {
    /// Runs `program` with `args` in `cwd` on a PTY of `cols` by `rows`.
    pub fn spawn(program: &str, args: &[String], cwd: Option<&str>, cols: u16, rows: u16) -> Result<Session, String> {
        let pair = native_pty_system()
            .openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| e.to_string())?;
        let mut command = CommandBuilder::new(program);
        command.args(args);
        command.env("TERM", "xterm-256color");
        command.env("COLORTERM", "truecolor");
        if let Some(dir) = cwd {
            command.cwd(dir);
        }
        let child = pair.slave.spawn_command(command).map_err(|e| e.to_string())?;
        drop(pair.slave);
        let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
        let writer = Arc::new(Mutex::new(pair.master.take_writer().map_err(|e| e.to_string())?));
        let parser = Arc::new(Mutex::new(vt100::Parser::new(rows, cols, SCROLLBACK)));
        let revision = Arc::new(AtomicU32::new(1));
        let exit = Arc::new(AtomicI32::new(-1));
        let session = Session {
            parser: parser.clone(),
            writer: writer.clone(),
            master: Mutex::new(pair.master),
            child: Mutex::new(child),
            revision: revision.clone(),
            exit: exit.clone(),
            hashes: Mutex::new(Vec::new()),
        };
        thread::spawn(move || {
            let mut buffer = [0u8; 16 * 1024];
            loop {
                match reader.read(&mut buffer) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        let chunk = &buffer[..n];
                        let mut answers = Vec::new();
                        {
                            let mut p = lock(&parser);
                            p.process(chunk);
                            answer_queries(chunk, p.screen(), &mut answers);
                        }
                        revision.fetch_add(1, Ordering::Relaxed);
                        if !answers.is_empty() {
                            // Replies take the writer's lock as typing does.
                            let _ = lock(&writer).write_all(&answers);
                        }
                    }
                }
            }
            exit.store(-2, Ordering::Relaxed);
            revision.fetch_add(1, Ordering::Relaxed);
        });
        Ok(session)
    }

    pub fn write(&self, bytes: &[u8]) -> bool {
        let mut w = lock(&self.writer);
        w.write_all(bytes).is_ok() && w.flush().is_ok()
    }

    pub fn resize(&self, cols: u16, rows: u16) {
        let _ = lock(&self.master).resize(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 });
        lock(&self.parser).set_size(rows, cols);
        lock(&self.hashes).clear();
        self.revision.fetch_add(1, Ordering::Relaxed);
    }

    pub fn revision(&self) -> i32 {
        self.revision.load(Ordering::Relaxed) as i32
    }

    /// -1 while the program runs, else its exit code (0 when it ended without one the platform reports).
    pub fn exit_code(&self) -> i32 {
        if self.exit.load(Ordering::Relaxed) == -1 {
            return -1;
        }
        match lock(&self.child).try_wait() {
            Ok(Some(status)) => status.exit_code() as i32,
            Ok(None) => -1,
            Err(_) => 0,
        }
    }

    pub fn set_scrollback(&self, lines: usize) -> usize {
        let mut p = lock(&self.parser);
        p.set_scrollback(lines);
        lock(&self.hashes).clear();
        self.revision.fetch_add(1, Ordering::Relaxed);
        p.screen().scrollback()
    }

    /// Sixteen bytes: rows, cols, cursor row, cursor column (u16 each), flags (1 cursor shown, 2 application cursor keys,
    /// 4 bracketed paste, 8 alternate screen, 16 application keypad), mouse mode (0 none, 1 press, 2 press and release,
    /// 3 button motion, 4 any motion), mouse encoding (0 default, 1 utf-8, 2 sgr), a pad byte, and the scrollback offset (u16).
    pub fn info(&self) -> [u8; 16] {
        let p = lock(&self.parser);
        let s = p.screen();
        let (rows, cols) = s.size();
        let (cr, cc) = s.cursor_position();
        let mut flags = 0u8;
        if !s.hide_cursor() {
            flags |= 1;
        }
        if s.application_cursor() {
            flags |= 2;
        }
        if s.bracketed_paste() {
            flags |= 4;
        }
        if s.alternate_screen() {
            flags |= 8;
        }
        if s.application_keypad() {
            flags |= 16;
        }
        let mode = match s.mouse_protocol_mode() {
            vt100::MouseProtocolMode::None => 0,
            vt100::MouseProtocolMode::Press => 1,
            vt100::MouseProtocolMode::PressRelease => 2,
            vt100::MouseProtocolMode::ButtonMotion => 3,
            vt100::MouseProtocolMode::AnyMotion => 4,
        };
        let encoding = match s.mouse_protocol_encoding() {
            vt100::MouseProtocolEncoding::Default => 0,
            vt100::MouseProtocolEncoding::Utf8 => 1,
            vt100::MouseProtocolEncoding::Sgr => 2,
        };
        let mut out = [0u8; 16];
        out[0..2].copy_from_slice(&rows.to_le_bytes());
        out[2..4].copy_from_slice(&cols.to_le_bytes());
        out[4..6].copy_from_slice(&cr.to_le_bytes());
        out[6..8].copy_from_slice(&cc.to_le_bytes());
        out[8] = flags;
        out[9] = mode;
        out[10] = encoding;
        out[12..14].copy_from_slice(&(s.scrollback() as u16).to_le_bytes());
        out
    }

    /// One byte for each row of the screen, 1 where it differs from when this was last asked.
    pub fn dirty(&self) -> Vec<u8> {
        let p = lock(&self.parser);
        let s = p.screen();
        let (rows, cols) = s.size();
        let mut hashes = lock(&self.hashes);
        let fresh = hashes.len() != rows as usize;
        if fresh {
            *hashes = vec![0; rows as usize];
        }
        let mut out = vec![0u8; rows as usize];
        for row in 0..rows {
            let mut h = DefaultHasher::new();
            for col in 0..cols {
                if let Some(c) = s.cell(row, col) {
                    c.contents().hash(&mut h);
                    encode_color(c.fgcolor()).hash(&mut h);
                    encode_color(c.bgcolor()).hash(&mut h);
                    attributes(c).hash(&mut h);
                }
            }
            let value = h.finish() | 1;
            if fresh || hashes[row as usize] != value {
                out[row as usize] = 1;
                hashes[row as usize] = value;
            }
        }
        out
    }

    /// Row `row` as runs of equally styled text, each: start column and width in cells (u16 each), attributes (u8),
    /// foreground and background (u32 each: 0 default, 1<<24 | index, 2<<24 | rgb), then the text's length (u16) and its UTF-8.
    pub fn row(&self, row: u16) -> Vec<u8> {
        let p = lock(&self.parser);
        let s = p.screen();
        let (_, cols) = s.size();
        let mut out = Vec::new();
        let mut open: Option<Run> = None;
        let mut col = 0;
        while col < cols {
            let Some(cell) = s.cell(row, col) else {
                col += 1;
                continue;
            };
            if cell.is_wide_continuation() {
                col += 1;
                continue;
            }
            let wide = cell.is_wide();
            let width: u16 = if wide { 2 } else { 1 };
            let mut text = cell.contents();
            if text.is_empty() {
                text.push(' ');
            }
            let (attrs, fg, bg) = (attributes(cell), encode_color(cell.fgcolor()), encode_color(cell.bgcolor()));
            let inverse = attrs & 8 != 0;
            let blank = text == " " && bg == 0 && !inverse && attrs & 4 == 0;
            if blank {
                finish(&mut open, &mut out);
                col += width;
                continue;
            }
            // A wide character stands alone, so its neighbours keep their columns whatever the font does with it.
            let joins = !wide && matches!(&open, Some(r) if r.attrs == attrs && r.fg == fg && r.bg == bg && r.start + r.cells == col && !r.wide);
            if joins {
                if let Some(r) = open.as_mut() {
                    r.text.push_str(&text);
                    r.cells += width;
                }
            } else {
                finish(&mut open, &mut out);
                open = Some(Run { start: col, cells: width, attrs, fg, bg, text, wide });
            }
            col += width;
        }
        finish(&mut open, &mut out);
        out
    }

    /// The text between two cells of the screen, for copying.
    pub fn text(&self, row1: u16, col1: u16, row2: u16, col2: u16) -> String {
        lock(&self.parser).screen().contents_between(row1, col1, row2, col2)
    }

    pub fn kill(&self) {
        let _ = lock(&self.child).kill();
    }
}

struct Run {
    start: u16,
    cells: u16,
    attrs: u8,
    fg: u32,
    bg: u32,
    text: String,
    wide: bool,
}

fn finish(open: &mut Option<Run>, out: &mut Vec<u8>) {
    if let Some(r) = open.take() {
        let bytes = r.text.as_bytes();
        out.extend_from_slice(&r.start.to_le_bytes());
        out.extend_from_slice(&r.cells.to_le_bytes());
        out.push(r.attrs);
        out.extend_from_slice(&r.fg.to_le_bytes());
        out.extend_from_slice(&r.bg.to_le_bytes());
        out.extend_from_slice(&(bytes.len() as u16).to_le_bytes());
        out.extend_from_slice(bytes);
    }
}

fn encode_color(c: vt100::Color) -> u32 {
    match c {
        vt100::Color::Default => 0,
        vt100::Color::Idx(i) => (1 << 24) | i as u32,
        vt100::Color::Rgb(r, g, b) => (2 << 24) | (r as u32) << 16 | (g as u32) << 8 | b as u32,
    }
}

/// Bold 1, italic 2, underline 4, inverse 8.
fn attributes(c: &vt100::Cell) -> u8 {
    (c.bold() as u8) | (c.italic() as u8) << 1 | (c.underline() as u8) << 2 | (c.inverse() as u8) << 3
}

/// Replies a terminal owes a program that asks: the cursor's place, and what the terminal is.
fn answer_queries(chunk: &[u8], screen: &vt100::Screen, out: &mut Vec<u8>) {
    let has = |needle: &[u8]| chunk.windows(needle.len()).any(|w| w == needle);
    if has(b"\x1b[6n") {
        let (row, col) = screen.cursor_position();
        out.extend_from_slice(format!("\x1b[{};{}R", row + 1, col + 1).as_bytes());
    }
    if has(b"\x1b[c") || has(b"\x1b[0c") {
        out.extend_from_slice(b"\x1b[?1;2c");
    }
    if has(b"\x1b[>c") || has(b"\x1b[>0c") {
        out.extend_from_slice(b"\x1b[>0;0;0c");
    }
}

// ---- The VM's side: sessions by handle, and primitives over them.

/// Open sessions by handle; a closed one leaves its slot empty.
static SESSIONS: Mutex<Vec<Option<Arc<Session>>>> = Mutex::new(Vec::new());

fn session(handle: i32) -> Option<Arc<Session>> {
    lock(&SESSIONS).get(handle as usize).and_then(|s| s.clone())
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
                all.push(Some(Arc::new(s)));
                (all.len() - 1) as i32
            }
            Err(_) => -1,
        }
    })
    .unwrap_or(-1)
}
define_prim!(hlp_term_open, term_open, "PiiBiBiBi_i");

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
    catch_unwind(|| session(handle).map_or(-3, |s| s.exit_code())).unwrap_or(-3)
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

/// Ends the program and frees the session.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn term_close(handle: i32) -> i32 {
    catch_unwind(|| {
        let taken = lock(&SESSIONS).get_mut(handle as usize).and_then(|s| s.take());
        match taken {
            Some(s) => {
                s.kill();
                1
            }
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

    /// Waits until `done` holds of the screen's text, or three seconds pass.
    fn wait(s: &Session, done: impl Fn(&str) -> bool) -> String {
        let end = Instant::now() + Duration::from_secs(3);
        loop {
            let (rows, cols) = lock(&s.parser).screen().size();
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
