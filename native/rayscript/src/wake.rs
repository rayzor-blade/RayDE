/// The platform adapter's thread-safe wake primitive takes no managed arguments.
pub(crate) fn platform_wake() -> Option<unsafe extern "C" fn() -> bool> {
    #[cfg(unix)]
    unsafe {
        #[cfg_attr(target_os = "linux", link(name = "dl"))]
        unsafe extern "C" { fn dlsym(handle: *mut std::ffi::c_void, name: *const std::ffi::c_char) -> *mut std::ffi::c_void; }
        #[cfg(target_os = "macos")]
        let scope = -2isize as *mut std::ffi::c_void;
        #[cfg(not(target_os = "macos"))]
        let scope = std::ptr::null_mut();
        let symbol = dlsym(scope, c"__hl_window_wake".as_ptr());
        if !symbol.is_null() { return Some(std::mem::transmute::<*mut std::ffi::c_void, unsafe extern "C" fn() -> bool>(symbol)); }
    }
    #[cfg(windows)]
    unsafe {
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn GetModuleHandleW(name: *const u16) -> *mut std::ffi::c_void;
            fn GetProcAddress(module: *mut std::ffi::c_void, name: *const std::ffi::c_char) -> *mut std::ffi::c_void;
        }
        let name: Vec<u16> = "xwindow.hdll\0".encode_utf16().collect();
        let module = GetModuleHandleW(name.as_ptr());
        if !module.is_null() {
            let symbol = GetProcAddress(module, c"__hl_window_wake".as_ptr());
            if !symbol.is_null() { return Some(std::mem::transmute::<*mut std::ffi::c_void, unsafe extern "C" fn() -> bool>(symbol)); }
        }
    }
    None
}
