use std::{
    collections::HashMap,
    io::Cursor,
    sync::{
        Arc, Mutex, OnceLock, Weak,
        atomic::{AtomicBool, AtomicI32, Ordering},
        mpsc,
    },
};

struct Job {
    input: Mutex<Option<(Vec<u8>, bool)>>,
    result: Mutex<Option<Result<Vec<u8>, String>>>,
    cancelled: AtomicBool,
}

static JOBS: OnceLock<Mutex<HashMap<i32, Arc<Job>>>> = OnceLock::new();
static IDS: AtomicI32 = AtomicI32::new(1);

fn jobs() -> &'static Mutex<HashMap<i32, Arc<Job>>> {
    JOBS.get_or_init(Default::default)
}

fn worker() -> Option<&'static mpsc::Sender<Weak<Job>>> {
    static WORKER: OnceLock<Option<mpsc::Sender<Weak<Job>>>> = OnceLock::new();
    WORKER
        .get_or_init(|| {
            let (tx, rx) = mpsc::channel::<Weak<Job>>();
            // Queued jobs must not retain encoded input after their view closes.
            std::thread::Builder::new()
                .name("rayde-image".into())
                .spawn(move || {
                    for next in rx {
                        let Some(job) = next.upgrade() else {
                            continue;
                        };
                        if job.cancelled.load(Ordering::Acquire) {
                            continue;
                        }
                        let Some((bytes, avif)) = job.input.lock().unwrap().take() else {
                            continue;
                        };
                        let result = std::panic::catch_unwind(|| decode(&bytes, avif))
                            .unwrap_or_else(|_| Err("Image decoder failed".into()));
                        if !job.cancelled.load(Ordering::Acquire) {
                            *job.result.lock().unwrap() = Some(result);
                        }
                    }
                })
                .ok()?;
            Some(tx)
        })
        .as_ref()
}

pub fn open(bytes: Vec<u8>, avif: bool) -> i32 {
    let Some(worker) = worker() else {
        return -1;
    };
    let id = IDS.fetch_add(1, Ordering::Relaxed);
    if id <= 0 {
        return -1;
    }
    let job = Arc::new(Job {
        input: Mutex::new(Some((bytes, avif))),
        result: Mutex::new(None),
        cancelled: AtomicBool::new(false),
    });
    jobs().lock().unwrap().insert(id, job.clone());
    if worker.send(Arc::downgrade(&job)).is_err() {
        close(id);
        return -1;
    }
    id
}

pub fn poll(id: i32) -> Option<Result<Vec<u8>, String>> {
    let job = jobs().lock().unwrap().get(&id)?.clone();
    job.result.lock().unwrap().take()
}

pub fn close(id: i32) {
    if let Some(job) = jobs().lock().unwrap().remove(&id) {
        job.cancelled.store(true, Ordering::Release);
    }
}

fn decode(bytes: &[u8], avif: bool) -> Result<Vec<u8>, String> {
    let image = if avif {
        avif_image(bytes)?
    } else {
        image::ImageReader::new(Cursor::new(bytes))
            .with_guessed_format()
            .map_err(|e| e.to_string())?
            .decode()
            .map_err(|e| e.to_string())?
    };
    let mut png = Cursor::new(Vec::new());
    image
        .write_to(&mut png, image::ImageFormat::Png)
        .map_err(|e| e.to_string())?;
    Ok(png.into_inner())
}

fn avif_image(bytes: &[u8]) -> Result<image::DynamicImage, String> {
    use avif_decode::Image;
    let decoded = avif_decode::Decoder::from_avif(bytes)
        .and_then(|d| d.to_image())
        .map_err(|e| e.to_string())?;
    macro_rules! rgba {
        ($img:expr, $convert:expr) => {{
            let img = $img;
            let (w, h) = (
                u32::try_from(img.width()).map_err(|_| "Image too wide")?,
                u32::try_from(img.height()).map_err(|_| "Image too tall")?,
            );
            let pixels: Vec<u8> = img
                .rows()
                .flat_map(|row| row.iter().flat_map($convert))
                .collect();
            image::DynamicImage::ImageRgba8(
                image::RgbaImage::from_raw(w, h, pixels).ok_or("Invalid AVIF dimensions")?,
            )
        }};
    }
    Ok(match decoded {
        Image::Rgb8(img) => rgba!(img, |p| [p.r, p.g, p.b, 255]),
        Image::Rgba8(img) => rgba!(img, |p| [p.r, p.g, p.b, p.a]),
        Image::Gray8(img) => rgba!(img, |p| [p.value(), p.value(), p.value(), 255]),
        Image::Rgb16(img) => rgba!(img, |p| [
            (p.r >> 8) as u8,
            (p.g >> 8) as u8,
            (p.b >> 8) as u8,
            255
        ]),
        Image::Rgba16(img) => rgba!(img, |p| [
            (p.r >> 8) as u8,
            (p.g >> 8) as u8,
            (p.b >> 8) as u8,
            (p.a >> 8) as u8
        ]),
        Image::Gray16(img) => rgba!(img, |p| [
            (p.value() >> 8) as u8,
            (p.value() >> 8) as u8,
            (p.value() >> 8) as u8,
            255
        ]),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_additional_formats_and_rejects_damage() {
        for (bytes, avif) in [
            (
                &include_bytes!("../../../tests/fixtures/images/sample.bmp")[..],
                false,
            ),
            (
                &include_bytes!("../../../tests/fixtures/images/sample.gif")[..],
                false,
            ),
            (
                &include_bytes!("../../../tests/fixtures/images/sample.ico")[..],
                false,
            ),
            (
                &include_bytes!("../../../tests/fixtures/images/sample-png.ico")[..],
                false,
            ),
            (
                &include_bytes!("../../../tests/fixtures/images/sample.avif")[..],
                true,
            ),
        ] {
            let png = decode(bytes, avif).unwrap();
            let image = image::load_from_memory(&png).unwrap();
            let expected = if bytes.len() > 4 && bytes[..4] == [0, 0, 1, 0] {
                (64, 64)
            } else {
                (64, 48)
            };
            assert_eq!((image.width(), image.height()), expected);
        }
        assert!(decode(b"broken", false).is_err());
        assert!(decode(b"broken", true).is_err());
    }

    #[test]
    fn closing_jobs_removes_their_inputs_and_results() {
        for _ in 0..20 {
            let id = open(
                include_bytes!("../../../tests/fixtures/images/sample.avif").to_vec(),
                true,
            );
            assert!(id > 0);
            close(id);
            assert!(!jobs().lock().unwrap().contains_key(&id));
            assert!(poll(id).is_none());
            close(id);
        }
        let id = open(
            include_bytes!("../../../tests/fixtures/images/sample.gif").to_vec(),
            false,
        );
        let start = std::time::Instant::now();
        loop {
            if let Some(result) = poll(id) {
                assert!(result.is_ok());
                break;
            }
            assert!(start.elapsed() < std::time::Duration::from_secs(10));
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        close(id);
        assert!(!jobs().lock().unwrap().contains_key(&id));
    }
}
