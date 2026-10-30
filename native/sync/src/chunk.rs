//! Content-defined chunking and hashing. A file is cut where its own bytes say to (a gear hash), so inserting at the start of a file changes
//! the first chunk or two and leaves the rest identical: an edited large file uploads only what changed.
use sha2::{Digest, Sha256};
use std::io::{self, Read};

/// The smallest chunk but the last, in bytes.
pub const MIN_CHUNK: usize = 256 * 1024;
/// The size a chunk averages near.
pub const AVERAGE_CHUNK: usize = 1024 * 1024;
/// The largest chunk. A manifest naming a bigger one is refused.
pub const MAX_CHUNK: usize = 4 * 1024 * 1024;

// A cut where the low 20 bits of the hash are zero averages 1 MiB past the minimum.
const MASK: u64 = (1 << 20) - 1;

const fn gear_table() -> [u64; 256] {
    // splitmix64, fixed seed: the table is part of the format, so every client cuts the same way.
    let mut table = [0u64; 256];
    let mut state: u64 = 0x9E37_79B9_7F4A_7C15;
    let mut i = 0;
    while i < 256 {
        state = state.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = state;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        table[i] = z ^ (z >> 31);
        i += 1;
    }
    table
}

static GEAR: [u64; 256] = gear_table();

pub fn sha256_hex(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}

pub fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut out = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        out.push(DIGITS[(b >> 4) as usize] as char);
        out.push(DIGITS[(b & 15) as usize] as char);
    }
    out
}

/// A cut piece of a stream.
#[derive(Clone, PartialEq, Eq, Debug)]
pub struct Piece {
    pub offset: u64,
    pub size: usize,
    /// SHA-256, lowercase hex.
    pub hash: String,
}

/// Where the next chunk of `data` ends: a cut point past the minimum, or the maximum, or the end. `data` is what is buffered so far.
fn cut(data: &[u8], last: bool) -> Option<usize> {
    if data.len() <= MIN_CHUNK {
        return if last { Some(data.len()) } else { None };
    }
    let limit = data.len().min(MAX_CHUNK);
    let mut hash = 0u64;
    for (i, b) in data[..limit].iter().enumerate() {
        hash = (hash << 1).wrapping_add(GEAR[*b as usize]);
        if i + 1 >= MIN_CHUNK && hash & MASK == 0 {
            return Some(i + 1);
        }
    }
    if limit == MAX_CHUNK {
        Some(MAX_CHUNK)
    } else if last {
        Some(limit)
    } else {
        None
    }
}

/// Reads `source` to its end, calling `each` with every chunk's piece and bytes, holding at most one maximum-size chunk plus a read buffer
/// in memory, so a large file is never held whole. An empty stream has no chunks.
pub fn chunks<R: Read>(mut source: R, mut each: impl FnMut(&Piece, &[u8]) -> io::Result<()>) -> io::Result<Vec<Piece>> {
    let mut buffer: Vec<u8> = Vec::with_capacity(MAX_CHUNK + 64 * 1024);
    let (mut offset, mut pieces, mut done) = (0u64, Vec::new(), false);
    let mut read = vec![0u8; 64 * 1024];
    loop {
        while !done && buffer.len() < MAX_CHUNK + read.len() {
            let n = source.read(&mut read)?;
            if n == 0 {
                done = true;
            } else {
                buffer.extend_from_slice(&read[..n]);
            }
            if n != 0 && buffer.len() >= MAX_CHUNK {
                break;
            }
        }
        if buffer.is_empty() {
            return Ok(pieces);
        }
        let Some(size) = cut(&buffer, done) else { continue };
        let piece = Piece { offset, size, hash: sha256_hex(&buffer[..size]) };
        each(&piece, &buffer[..size])?;
        pieces.push(piece);
        offset += size as u64;
        buffer.drain(..size);
    }
}

/// The hash of a whole stream, for checking it against a manifest without cutting it.
pub fn hash_reader<R: Read>(mut source: R) -> io::Result<(String, u64)> {
    let (mut hasher, mut size, mut read) = (Sha256::new(), 0u64, vec![0u8; 64 * 1024]);
    loop {
        let n = source.read(&mut read)?;
        if n == 0 {
            return Ok((hex(&hasher.finalize()), size));
        }
        hasher.update(&read[..n]);
        size += n as u64;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Bytes that look like content: a seeded generator, deterministic.
    fn data(len: usize, seed: u64) -> Vec<u8> {
        let mut state = seed;
        (0..len)
            .map(|_| {
                state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                (state >> 33) as u8
            })
            .collect()
    }

    fn cut_all(bytes: &[u8]) -> Vec<Piece> {
        chunks(bytes, |_, _| Ok(())).unwrap()
    }

    #[test]
    fn sha256_matches_the_standard_vectors() {
        assert_eq!(sha256_hex(b""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855");
        assert_eq!(sha256_hex(b"abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
    }

    #[test]
    fn nothing_makes_no_chunks_and_a_small_file_makes_one() {
        assert!(cut_all(b"").is_empty());
        let small = data(10_000, 1);
        let pieces = cut_all(&small);
        assert_eq!((pieces.len(), pieces[0].size, pieces[0].hash.clone()), (1, 10_000, sha256_hex(&small)));
    }

    #[test]
    fn chunks_tile_the_stream_and_respect_the_size_bounds() {
        let bytes = data(20 * 1024 * 1024, 2);
        let mut rebuilt = Vec::new();
        let pieces = chunks(&bytes[..], |_, part| {
            rebuilt.extend_from_slice(part);
            Ok(())
        })
        .unwrap();
        assert_eq!(rebuilt, bytes, "the chunks, in order, are the stream");
        let mut offset = 0;
        for (i, p) in pieces.iter().enumerate() {
            assert_eq!(p.offset, offset);
            assert!(p.size <= MAX_CHUNK);
            if i + 1 < pieces.len() {
                assert!(p.size >= MIN_CHUNK, "{i}: {}", p.size);
            }
            offset += p.size as u64;
        }
        assert_eq!(offset, bytes.len() as u64);
        assert!(pieces.len() > 5 && pieces.len() < 80, "around 1 MiB each: {}", pieces.len());
    }

    #[test]
    fn the_same_bytes_cut_the_same_whatever_the_reads_are() {
        struct Dribble<'a>(&'a [u8]);
        impl Read for Dribble<'_> {
            fn read(&mut self, out: &mut [u8]) -> io::Result<usize> {
                let n = out.len().min(self.0.len()).min(7919);
                out[..n].copy_from_slice(&self.0[..n]);
                self.0 = &self.0[n..];
                Ok(n)
            }
        }
        let bytes = data(6 * 1024 * 1024, 3);
        assert_eq!(chunks(Dribble(&bytes), |_, _| Ok(())).unwrap(), cut_all(&bytes));
    }

    #[test]
    fn an_insertion_at_the_start_changes_a_few_chunks_and_not_the_rest() {
        let original = data(16 * 1024 * 1024, 4);
        let mut edited = b"inserted at the front".to_vec();
        edited.extend_from_slice(&original);
        let (a, b) = (cut_all(&original), cut_all(&edited));
        let known: std::collections::HashSet<&String> = a.iter().map(|p| &p.hash).collect();
        let shared = b.iter().filter(|p| known.contains(&p.hash)).count();
        assert!(shared + 3 >= b.len(), "{shared} of {} chunks are shared", b.len());
    }

    #[test]
    fn a_stream_with_no_cut_points_is_cut_at_the_maximum() {
        let zeros = vec![0u8; 3 * MAX_CHUNK + 5];
        let pieces = cut_all(&zeros);
        assert!(pieces.iter().take(3).all(|p| p.size == MAX_CHUNK));
        assert_eq!(pieces.last().unwrap().size, 5);
    }

    #[test]
    fn hash_reader_agrees_with_the_whole_buffer() {
        let bytes = data(300_000, 5);
        assert_eq!(hash_reader(&bytes[..]).unwrap(), (sha256_hex(&bytes), 300_000));
    }
}
