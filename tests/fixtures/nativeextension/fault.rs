#[unsafe(no_mangle)]
pub extern "C" fn native_pid() -> i32 { std::process::id() as i32 }

#[unsafe(no_mangle)]
pub extern "C" fn native_abort() { std::process::abort(); }

#[unsafe(no_mangle)]
pub extern "C" fn native_hang() { loop { std::thread::park(); } }

#[unsafe(no_mangle)]
pub extern "C" fn native_noise() {
    use std::io::Write;
    let _ = std::io::stdout().write_all(b"native output is not a protocol message\n");
}

#[unsafe(no_mangle)]
pub extern "C" fn native_invalid_ops() {
    use std::io::Write;
    let _ = std::io::stdout().write_all(b"{\"t\":\"ops\",\"ops\":[[]]}\n");
}

#[unsafe(no_mangle)]
pub extern "C" fn native_large_output() {
    use std::io::Write;
    let _ = std::io::stdout().write_all(&vec![b'x'; 17 << 20]);
}

#[unsafe(no_mangle)]
pub extern "C" fn native_retain(bytes: i32) {
    let mut data = vec![0u8; bytes as usize];
    for byte in &mut data { *byte = 42; }
    std::hint::black_box(&data);
    std::mem::forget(data);
}
