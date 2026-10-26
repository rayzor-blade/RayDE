fn main() {
    if std::env::var_os("CARGO_FEATURE_FFI").is_none() { return; }
    // The VM's own symbols (hl_alloc_bytes) are resolved when it loads the library: Apple's linker needs telling,
    // Windows links the VM's import library from HL_LIB_DIR, and other Unixes leave them undefined as an hdll wants.
    println!("cargo:rerun-if-changed=build.rs");
    match std::env::var("CARGO_CFG_TARGET_VENDOR").as_deref() {
        Ok("apple") => println!("cargo:rustc-cdylib-link-arg=-Wl,-undefined,dynamic_lookup"),
        _ if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") => {
            println!("cargo:rerun-if-env-changed=HL_LIB_DIR");
            if let Ok(dir) = std::env::var("HL_LIB_DIR") {
                println!("cargo:rustc-link-search=native={dir}");
                println!("cargo:rustc-link-lib=dylib=libhl");
            }
        }
        _ => {}
    }
}
