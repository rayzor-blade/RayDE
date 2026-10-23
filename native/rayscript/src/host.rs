use std::{path::PathBuf, process::ExitCode};

fn main() -> ExitCode {
    let mut root = None;
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--root" => match args.next() { Some(path) => root = Some(PathBuf::from(path)), None => return ExitCode::from(2) },
            // Retained in the process command line for extension memory attribution.
            "--extension" => if args.next().is_none() { return ExitCode::from(2); },
            _ => return ExitCode::from(2),
        }
    }
    match rayde_rayscript::serve_extension(root) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => { eprintln!("rayde-extension-host: {error}"); ExitCode::FAILURE },
    }
}
