//! A shell on a pseudo-terminal, and the screen it draws, for RayDE's terminal tab.
//!
//! A session runs a program on a PTY. A thread reads what it prints into a
//! `vt100` screen, which keeps the grid, colours, cursor, scrollback and the
//! alternate screen. The VM never sees a cell: it asks which rows changed and
//! fetches those as runs of equally styled text, so a busy terminal costs the
//! VM a few rows a frame and not an object a cell.
use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use std::{
    collections::{hash_map::DefaultHasher,HashMap},
    hash::{Hash, Hasher},
    io::{Read, Write},
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
        Self::observed(program,args,cwd,cols,rows,SCROLLBACK,Arc::new(|| {}))
    }

    pub fn observed(program: &str, args: &[String], cwd: Option<&str>, cols: u16, rows: u16, scrollback:usize, changed:Arc<dyn Fn()+Send+Sync>) -> Result<Session, String> {
        Self::configured(program,args,cwd,cols,rows,scrollback,changed,&HashMap::new())
    }

    pub fn configured(program:&str,args:&[String],cwd:Option<&str>,cols:u16,rows:u16,scrollback:usize,changed:Arc<dyn Fn()+Send+Sync>,environment:&HashMap<String,String>)->Result<Session,String>{
        let pair = native_pty_system()
            .openpty(PtySize { rows, cols, pixel_width: 0, pixel_height: 0 })
            .map_err(|e| e.to_string())?;
        let mut command = CommandBuilder::new(program);
        command.args(args);
        for (key,value) in environment {command.env(key,value);}
        command.env("TERM", "xterm-256color");
        command.env("COLORTERM", "truecolor");
        if let Some(dir) = cwd {
            command.cwd(dir);
        }
        let child = pair.slave.spawn_command(command).map_err(|e| e.to_string())?;
        drop(pair.slave);
        let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
        let writer = Arc::new(Mutex::new(pair.master.take_writer().map_err(|e| e.to_string())?));
        let parser = Arc::new(Mutex::new(vt100::Parser::new(rows, cols, scrollback)));
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
                        changed();
                        if !answers.is_empty() {
                            // Replies take the writer's lock as typing does.
                            let _ = lock(&writer).write_all(&answers);
                        }
                    }
                }
            }
            exit.store(-2, Ordering::Relaxed);
            revision.fetch_add(1, Ordering::Relaxed);
            changed();
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

    pub fn output_closed(&self)->bool {self.exit.load(Ordering::Relaxed)!=-1}

    /// Text and UTF-16 boundaries by terminal column, including wide and combining characters.
    pub fn copy_row(&self,row:u16)->(String,Vec<u16>){
        let p=lock(&self.parser);let s=p.screen();let (_,cols)=s.size();
        let mut text=String::new();let mut offsets=Vec::with_capacity(cols as usize+1);let mut units=0;
        for col in 0..cols {
            if s.cell(row,col).is_some_and(|c|c.is_wide_continuation()) {offsets.push(*offsets.last().unwrap_or(&0));continue;}
            offsets.push(units);
            let value=s.cell(row,col).map(|c|c.contents()).filter(|s|!s.is_empty()).unwrap_or_else(||" ".into());
            units+=value.encode_utf16().count() as u16;text.push_str(&value);
        }
        offsets.push(units);(text,offsets)
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

    /// Makes the next ask of `dirty` report every row, for a view that has just taken over from another.
    pub fn invalidate(&self) {
        lock(&self.hashes).clear();
        self.revision.fetch_add(1, Ordering::Relaxed);
    }

    pub fn kill(&self) {
        let _ = lock(&self.child).kill();
    }

    /// Hard cleanup for a disconnected remote owner, including the PTY's process group.
    pub fn terminate(&self) {
        let mut child=lock(&self.child);
        if matches!(child.try_wait(),Ok(Some(_))){return;}
        #[cfg(unix)]
        if let Some(pid)=child.process_id(){unsafe {libc::kill(-(pid as i32),libc::SIGKILL);}}
        let _=child.kill();let _=child.wait();
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

