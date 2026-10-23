use super::*;
use hl_abi::{define_prim, hl_alloc_bytes, vbyte};
use std::ptr;

static RUNTIMES: Mutex<Vec<Option<Arc<Runtime>>>> = Mutex::new(Vec::new());

#[unsafe(no_mangle)]
pub unsafe extern "C" fn jam_document_open(data:*const vbyte,len:i32) -> i32 {
    catch_unwind(||unsafe {text(data,len)}.map_or(-1,super::jam::document_open)).unwrap_or(-1)
}
define_prim!(hlp_jam_document_open,jam_document_open,"PBi_i");
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jam_document_call(id:i32,data:*const vbyte,len:i32) -> *mut vbyte {
    catch_unwind(||unsafe {text(data,len)}.map_or(ptr::null_mut(),|s|packed_text(&super::jam::document_call(id,s)))).unwrap_or(ptr::null_mut())
}
define_prim!(hlp_jam_document_call,jam_document_call,"PiBi_B");
#[unsafe(no_mangle)]
pub extern "C" fn jam_document_close(id:i32) { let _=catch_unwind(||super::jam::document_close(id)); }
define_prim!(hlp_jam_document_close,jam_document_close,"Pi_v");
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jam_session_open(data:*const vbyte,len:i32) -> i32 {
    catch_unwind(||unsafe {text(data,len)}.map_or(-1,super::jam::session_open)).unwrap_or(-1)
}
define_prim!(hlp_jam_session_open,jam_session_open,"PBi_i");
#[unsafe(no_mangle)]
pub unsafe extern "C" fn jam_session_send(id:i32,data:*const vbyte,len:i32) -> bool {
    catch_unwind(||unsafe {text(data,len)}.is_some_and(|s|super::jam::session_send(id,s))).unwrap_or(false)
}
define_prim!(hlp_jam_session_send,jam_session_send,"PiBi_b");
#[unsafe(no_mangle)]
pub extern "C" fn jam_session_poll(id:i32) -> *mut vbyte {
    catch_unwind(||super::jam::session_poll(id).map_or(ptr::null_mut(),|s|packed_text(&s))).unwrap_or(ptr::null_mut())
}
define_prim!(hlp_jam_session_poll,jam_session_poll,"Pi_B");
#[unsafe(no_mangle)]
pub extern "C" fn jam_session_pending(id:i32) -> bool { catch_unwind(||super::jam::session_pending(id)).unwrap_or(false) }
define_prim!(hlp_jam_session_pending,jam_session_pending,"Pi_b");
#[unsafe(no_mangle)]
pub extern "C" fn jam_session_can_wake(id:i32) -> bool { catch_unwind(||super::jam::session_can_wake(id)).unwrap_or(false) }
define_prim!(hlp_jam_session_can_wake,jam_session_can_wake,"Pi_b");
#[unsafe(no_mangle)]
pub extern "C" fn jam_session_close(id:i32) { let _=catch_unwind(||super::jam::session_close(id)); }
define_prim!(hlp_jam_session_close,jam_session_close,"Pi_v");

#[unsafe(no_mangle)]
pub extern "C" fn project_apple_silicon() -> bool {
    cfg!(all(target_os = "macos", target_arch = "aarch64"))
}
define_prim!(hlp_project_apple_silicon, project_apple_silicon, "P_b");

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
pub unsafe extern "C" fn extension_open(data:*const vbyte, len:i32) -> i32 {
    catch_unwind(|| unsafe { text(data,len) }.and_then(|s| super::extension_process::open(s).ok()).unwrap_or(-1)).unwrap_or(-1)
}
define_prim!(hlp_extension_open, extension_open, "PBi_i");

#[unsafe(no_mangle)]
pub unsafe extern "C" fn extension_send(handle:i32, data:*const vbyte, len:i32) -> bool {
    catch_unwind(|| unsafe { text(data,len) }.is_some_and(|s| super::extension_process::send(handle,s))).unwrap_or(false)
}
define_prim!(hlp_extension_send, extension_send, "PiBi_b");

#[unsafe(no_mangle)]
pub extern "C" fn extension_poll(handle:i32) -> *mut vbyte {
    catch_unwind(|| super::extension_process::poll(handle).map_or(ptr::null_mut(), |s| packed_text(&s))).unwrap_or(ptr::null_mut())
}
define_prim!(hlp_extension_poll, extension_poll, "Pi_B");

#[unsafe(no_mangle)]
pub extern "C" fn extension_status(handle:i32) -> i32 { catch_unwind(|| super::extension_process::status(handle)).unwrap_or(2) }
define_prim!(hlp_extension_status, extension_status, "Pi_i");

#[unsafe(no_mangle)]
pub extern "C" fn extension_pending(handle:i32) -> bool { catch_unwind(|| super::extension_process::pending(handle)).unwrap_or(false) }
define_prim!(hlp_extension_pending, extension_pending, "Pi_b");

#[unsafe(no_mangle)]
pub extern "C" fn extension_can_wake(handle:i32) -> bool { catch_unwind(|| super::extension_process::can_wake(handle)).unwrap_or(false) }
define_prim!(hlp_extension_can_wake, extension_can_wake, "Pi_b");

#[unsafe(no_mangle)]
pub extern "C" fn extension_close(handle:i32) { let _ = catch_unwind(|| super::extension_process::close(handle)); }
define_prim!(hlp_extension_close, extension_close, "Pi_v");

#[unsafe(no_mangle)]
pub unsafe extern "C" fn project_toml(data:*const vbyte, len:i32) -> *mut vbyte {
    catch_unwind(|| unsafe { text(data,len) }.map_or(ptr::null_mut(), |s| packed_text(&super::project::parse(s).to_string()))).unwrap_or(ptr::null_mut())
}
define_prim!(hlp_project_toml, project_toml, "PBi_B");

#[unsafe(no_mangle)]
pub unsafe extern "C" fn project_toml_edit(data:*const vbyte, len:i32) -> *mut vbyte {
    catch_unwind(|| unsafe { text(data,len) }.map_or(ptr::null_mut(), |s| packed_text(&super::project::edit(s).to_string()))).unwrap_or(ptr::null_mut())
}
define_prim!(hlp_project_toml_edit, project_toml_edit, "PBi_B");

#[unsafe(no_mangle)]
pub unsafe extern "C" fn project_directory(data:*const vbyte, len:i32) -> *mut vbyte {
    catch_unwind(|| unsafe { text(data,len) }.map_or(ptr::null_mut(), |s| packed_text(&super::project::create_directory(s).to_string()))).unwrap_or(ptr::null_mut())
}
define_prim!(hlp_project_directory, project_directory, "PBi_B");

#[unsafe(no_mangle)]
pub unsafe extern "C" fn lsp_open(data:*const vbyte, len:i32) -> i32 {
    catch_unwind(|| unsafe { text(data,len) }.and_then(|s| super::lsp::open(s).ok()).unwrap_or(-1)).unwrap_or(-1)
}
define_prim!(hlp_lsp_open, lsp_open, "PBi_i");

#[unsafe(no_mangle)]
pub unsafe extern "C" fn lsp_send(handle:i32, data:*const vbyte, len:i32) -> bool {
    catch_unwind(|| unsafe { text(data,len) }.is_some_and(|s| super::lsp::send(handle,s))).unwrap_or(false)
}
define_prim!(hlp_lsp_send, lsp_send, "PiBi_b");

#[unsafe(no_mangle)]
pub extern "C" fn lsp_poll(handle:i32) -> *mut vbyte {
    catch_unwind(|| super::lsp::poll(handle).map_or(ptr::null_mut(), |s| packed_text(&s))).unwrap_or(ptr::null_mut())
}
define_prim!(hlp_lsp_poll, lsp_poll, "Pi_B");

#[unsafe(no_mangle)]
pub extern "C" fn lsp_pending(handle:i32) -> bool { catch_unwind(|| super::lsp::pending(handle)).unwrap_or(false) }
define_prim!(hlp_lsp_pending, lsp_pending, "Pi_b");

#[unsafe(no_mangle)]
pub extern "C" fn lsp_can_wake(handle:i32) -> bool { catch_unwind(|| super::lsp::can_wake(handle)).unwrap_or(false) }
define_prim!(hlp_lsp_can_wake, lsp_can_wake, "Pi_b");

#[unsafe(no_mangle)]
pub extern "C" fn lsp_close(handle:i32) {
    let _ = catch_unwind(|| super::lsp::close(handle));
}
define_prim!(hlp_lsp_close, lsp_close, "Pi_v");

#[unsafe(no_mangle)]
pub unsafe extern "C" fn image_open(data:*const vbyte, len:i32, avif:bool) -> i32 {
    catch_unwind(|| {
        if data.is_null() || len <= 0 { return -1; }
        super::image_preview::open(unsafe { std::slice::from_raw_parts(data, len as usize) }.to_vec(), avif)
    }).unwrap_or(-1)
}
define_prim!(hlp_image_open, image_open, "PBib_i");

#[unsafe(no_mangle)]
pub extern "C" fn image_poll(handle:i32) -> *mut vbyte {
    catch_unwind(|| {
        let Some(result) = super::image_preview::poll(handle) else { return ptr::null_mut(); };
        let (status, data) = match result { Ok(png) => (1_i32, png), Err(error) => (-1, error.into_bytes()) };
        let Some(length) = data.len().checked_add(8).and_then(|n| i32::try_from(n).ok()) else { return ptr::null_mut(); };
        unsafe {
            let bytes = hl_alloc_bytes(length);
            if bytes.is_null() { return ptr::null_mut(); }
            ptr::copy_nonoverlapping(status.to_le_bytes().as_ptr(), bytes, 4);
            ptr::copy_nonoverlapping((data.len() as i32).to_le_bytes().as_ptr(), bytes.add(4), 4);
            ptr::copy_nonoverlapping(data.as_ptr(), bytes.add(8), data.len());
            bytes
        }
    }).unwrap_or(ptr::null_mut())
}
define_prim!(hlp_image_poll, image_poll, "Pi_B");

#[unsafe(no_mangle)]
pub extern "C" fn image_close(handle:i32) {
    let _ = catch_unwind(|| super::image_preview::close(handle));
}
define_prim!(hlp_image_close, image_close, "Pi_v");

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

#[unsafe(no_mangle)]
pub unsafe extern "C" fn markdown_fragment(data:*const vbyte, len:i32) -> *mut vbyte {
    catch_unwind(|| {
        let Some(source) = (unsafe { text(data,len) }) else { return ptr::null_mut(); };
        super::markdown::fragment(source).map_or(ptr::null_mut(), |doc| packed_text(&doc.to_string()))
    }).unwrap_or(ptr::null_mut())
}
define_prim!(hlp_markdown_fragment, markdown_fragment, "PBi_B");

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
pub extern "C" fn runtime_pending(handle:i32) -> bool {
    catch_unwind(|| runtime(handle).is_some_and(|r| r.status.load(Ordering::Acquire) != 0 || !r.output.lock().unwrap().is_empty())).unwrap_or(false)
}
define_prim!(hlp_runtime_pending, runtime_pending, "Pi_b");

#[unsafe(no_mangle)]
pub extern "C" fn runtime_can_wake(handle:i32) -> bool {
    catch_unwind(|| runtime(handle).is_some_and(|r| r.wake.is_some())).unwrap_or(false)
}
define_prim!(hlp_runtime_can_wake, runtime_can_wake, "Pi_b");

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
