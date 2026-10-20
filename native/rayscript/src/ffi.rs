use super::*;
use hl_abi::{define_prim, hl_alloc_bytes, vbyte};
use std::ptr;

static RUNTIMES: Mutex<Vec<Option<Arc<Runtime>>>> = Mutex::new(Vec::new());

fn packed_text(text:&str) -> *mut vbyte {
    let size = text.len();
    let Some(length) = size.checked_add(4).and_then(|n| i32::try_from(n).ok()) else { return ptr::null_mut(); };
    unsafe {
        let bytes = hl_alloc_bytes(length);
        if bytes.is_null() { return ptr::null_mut(); }
        ptr::copy_nonoverlapping((size as i32).to_le_bytes().as_ptr(), bytes, 4);
        ptr::copy_nonoverlapping(text.as_ptr(), bytes.add(4), size);
        bytes
    }
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn syntax_open(data:*const vbyte, len:i32) -> i32 {
    catch_unwind(|| unsafe { text(data,len) }.map_or(-1, super::syntax::open)).unwrap_or(-1)
}
define_prim!(hlp_syntax_open, syntax_open, "PBi_i");

#[unsafe(no_mangle)]
pub extern "C" fn syntax_close(handle:i32) {
    let _ = catch_unwind(|| super::syntax::close(handle));
}
define_prim!(hlp_syntax_close, syntax_close, "Pi_v");

#[unsafe(no_mangle)]
pub unsafe extern "C" fn syntax_line(handle:i32, data:*const vbyte, len:i32, state:i32) -> *mut vbyte {
    catch_unwind(|| {
        let Some(line) = (unsafe { text(data,len) }) else { return ptr::null_mut(); };
        packed_text(&super::syntax::line(handle,line,state).to_string())
    }).unwrap_or(ptr::null_mut())
}
define_prim!(hlp_syntax_line, syntax_line, "PiBii_B");

fn runtime(handle: i32) -> Option<Arc<Runtime>> {
    RUNTIMES
        .lock()
        .ok()?
        .get(usize::try_from(handle).ok()?)?
        .clone()
}

unsafe fn text<'a>(data: *const vbyte, len: i32) -> Option<&'a str> {
    if data.is_null() || len < 0 {
        return None;
    }
    std::str::from_utf8(unsafe { std::slice::from_raw_parts(data, len as usize) }).ok()
}

fn send(handle: i32, command: Command) -> i32 {
    runtime(handle)
        .is_some_and(|r| r.status.load(Ordering::Acquire) == 0 && r.input.send(command).is_ok())
        as i32
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn runtime_open(root: *const vbyte, len: i32) -> i32 {
    catch_unwind(|| {
        let Some(root) = (unsafe { text(root, len) }) else {
            return -1;
        };
        let Ok(runtime) = Runtime::start((!root.is_empty()).then(|| PathBuf::from(root))) else {
            return -1;
        };
        let mut slots = RUNTIMES.lock().unwrap();
        let handle = slots.len() as i32;
        slots.push(Some(runtime));
        handle
    })
    .unwrap_or(-1)
}
define_prim!(hlp_runtime_open, runtime_open, "PBi_i");

#[unsafe(no_mangle)]
pub unsafe extern "C" fn runtime_send(handle: i32, data: *const vbyte, len: i32) -> i32 {
    catch_unwind(|| match unsafe { text(data, len) } {
        Some(line) => send(handle, Command::Message(line.to_owned())),
        None => 0,
    })
    .unwrap_or(0)
}
define_prim!(hlp_runtime_send, runtime_send, "PiBi_i");

#[unsafe(no_mangle)]
pub extern "C" fn runtime_close_view(handle: i32, root: i32) -> i32 {
    catch_unwind(|| {
        if root > 0 {
            send(handle, Command::CloseView(root as u32))
        } else {
            0
        }
    })
    .unwrap_or(0)
}
define_prim!(hlp_runtime_close_view, runtime_close_view, "Pii_i");

#[unsafe(no_mangle)]
pub extern "C" fn runtime_collect(handle: i32) -> i32 {
    catch_unwind(|| send(handle, Command::Collect)).unwrap_or(0)
}
define_prim!(hlp_runtime_collect, runtime_collect, "Pi_i");

#[unsafe(no_mangle)]
pub extern "C" fn runtime_status(handle: i32) -> i32 {
    catch_unwind(|| runtime(handle).map_or(1, |r| r.status.load(Ordering::Acquire))).unwrap_or(2)
}
define_prim!(hlp_runtime_status, runtime_status, "Pi_i");

#[unsafe(no_mangle)]
pub extern "C" fn runtime_poll(handle: i32) -> *mut vbyte {
    catch_unwind(|| {
        let Some(runtime) = runtime(handle) else {
            return ptr::null_mut();
        };
        let lines = std::mem::take(&mut *runtime.output.lock().unwrap());
        if lines.is_empty() {
            return ptr::null_mut();
        }
        let text = lines.join("\n");
        let bytes = text.as_bytes();
        let Some(size) = bytes
            .len()
            .checked_add(4)
            .and_then(|n| i32::try_from(n).ok())
        else {
            return ptr::null_mut();
        };
        // HashLink allocation is confined to the caller's thread.
        let out = unsafe { hl_alloc_bytes(size) };
        if !out.is_null() {
            unsafe {
                ptr::copy_nonoverlapping((bytes.len() as i32).to_le_bytes().as_ptr(), out, 4);
                ptr::copy_nonoverlapping(bytes.as_ptr(), out.add(4), bytes.len());
            }
        }
        out
    })
    .unwrap_or(ptr::null_mut())
}
define_prim!(hlp_runtime_poll, runtime_poll, "Pi_B");

#[unsafe(no_mangle)]
pub extern "C" fn runtime_close(handle: i32) -> i32 {
    catch_unwind(|| {
        let mut slots = RUNTIMES.lock().unwrap();
        let Some(slot) = usize::try_from(handle).ok().and_then(|i| slots.get_mut(i)) else {
            return 0;
        };
        let Some(runtime) = slot.take() else {
            return 0;
        };
        let _ = runtime.input.send(Command::Shutdown);
        1
    })
    .unwrap_or(0)
}
define_prim!(hlp_runtime_close, runtime_close, "Pi_i");
