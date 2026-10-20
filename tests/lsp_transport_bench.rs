//! Identical framed RPC loops over child-process pipes or TCP loopback, without compiler work.
use std::{
    io::{self, BufRead, BufReader, Write},
    net::{TcpListener, TcpStream},
    process::{Command, Stdio},
    time::Instant,
};

fn payload(size: usize) -> Vec<u8> {
    let mut bytes = br#"{"jsonrpc":"2.0","id":1,"result":""#.to_vec();
    bytes.resize(size.max(bytes.len() + 2) - 2, b'x');
    bytes.extend_from_slice(b"\"}");
    bytes
}
fn frame(body: &[u8]) -> Vec<u8> {
    let mut bytes = format!("Content-Length: {}\r\n\r\n", body.len()).into_bytes();
    bytes.extend_from_slice(body);
    bytes
}
fn read_frame(
    reader: &mut dyn BufRead,
    body: &mut Vec<u8>,
    header: &mut String,
) -> io::Result<bool> {
    let mut length = None;
    loop {
        header.clear();
        if reader.read_line(header)? == 0 {
            return Ok(false);
        }
        if header == "\r\n" {
            break;
        }
        if let Some(value) = header.strip_prefix("Content-Length:") {
            length = value.trim().parse::<usize>().ok();
        }
    }
    let size = length.ok_or_else(|| io::Error::other("missing Content-Length"))?;
    body.resize(size, 0);
    reader.read_exact(body)?;
    Ok(true)
}
fn worker(mut reader: impl BufRead, mut writer: impl Write, response: usize) -> io::Result<()> {
    let reply = frame(&payload(response));
    let mut body = Vec::new();
    let mut header = String::new();
    while read_frame(&mut reader, &mut body, &mut header)? {
        writer.write_all(&reply)?;
        writer.flush()?;
    }
    Ok(())
}
fn main() -> io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args[1] == "--worker" {
        let response = args[3].parse().unwrap();
        if args[2] == "stdio" {
            return worker(
                BufReader::new(io::stdin().lock()),
                io::stdout().lock(),
                response,
            );
        }
        let listener = TcpListener::bind("127.0.0.1:0")?;
        println!("{}", listener.local_addr()?.port());
        io::stdout().flush()?;
        let (stream, _) = listener.accept()?;
        stream.set_nodelay(true)?;
        return worker(BufReader::new(stream.try_clone()?), stream, response);
    }
    let mode = &args[1];
    let request: usize = args[2].parse().unwrap();
    let response: usize = args[3].parse().unwrap();
    let count: usize = args[4].parse().unwrap();
    let pipeline: bool = args[5] == "pipeline";
    let mut child = Command::new(std::env::current_exe()?)
        .args(["--worker", mode, &response.to_string()])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()?;
    let mut stdout = BufReader::new(child.stdout.take().unwrap());
    let (mut reader, mut writer): (Box<dyn BufRead + Send>, Box<dyn Write + Send>) =
        if mode == "stdio" {
            (Box::new(stdout), Box::new(child.stdin.take().unwrap()))
        } else {
            let mut port = String::new();
            stdout.read_line(&mut port)?;
            let stream = TcpStream::connect(("127.0.0.1", port.trim().parse::<u16>().unwrap()))?;
            stream.set_nodelay(true)?;
            (
                Box::new(BufReader::new(stream.try_clone()?)),
                Box::new(stream),
            )
        };
    let message = frame(&payload(request));
    let mut body = Vec::new();
    let mut header = String::new();
    for _ in 0..50 {
        writer.write_all(&message)?;
        writer.flush()?;
        assert!(read_frame(&mut reader, &mut body, &mut header)?);
    }
    let start = Instant::now();
    let mut latencies = Vec::with_capacity(count);
    if pipeline {
        std::thread::scope(|scope| -> io::Result<()> {
            let sender = scope.spawn(|| -> io::Result<()> {
                for _ in 0..count {
                    writer.write_all(&message)?;
                    writer.flush()?;
                }
                Ok(())
            });
            for _ in 0..count {
                assert!(read_frame(&mut reader, &mut body, &mut header)?);
            }
            sender.join().unwrap()
        })?;
    } else {
        for _ in 0..count {
            let at = Instant::now();
            writer.write_all(&message)?;
            writer.flush()?;
            assert!(read_frame(&mut reader, &mut body, &mut header)?);
            latencies.push(at.elapsed().as_nanos());
        }
    }
    let elapsed = start.elapsed().as_secs_f64();
    let _ = child.kill();
    child.wait()?;
    latencies.sort_unstable();
    let p50 = if pipeline {
        0.
    } else {
        latencies[count / 2] as f64 / 1000.
    };
    let p95 = if pipeline {
        0.
    } else {
        latencies[count * 95 / 100] as f64 / 1000.
    };
    println!(
        "{{\"seconds\":{elapsed},\"p50_us\":{p50},\"p95_us\":{p95},\"mib_s\":{}}}",
        ((request + response) * count) as f64 / 1048576. / elapsed
    );
    Ok(())
}
