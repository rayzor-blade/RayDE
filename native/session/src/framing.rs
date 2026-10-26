//! Length-prefixed session messages, shared by the native listener and compute provider.
use crate::session::MAX_MESSAGE;

pub fn frame(text: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len() + 4);
    out.extend_from_slice(&(text.len() as u32).to_be_bytes());
    out.extend_from_slice(text.as_bytes());
    out
}

/// Frames arriving in pieces of any size, put back together.
#[derive(Default)]
pub struct Frames {
    pending: Vec<u8>,
}

impl Frames {
    /// Adds `bytes` and returns the messages now complete. An error means the stream is not frames, and the connection should end.
    pub fn push(&mut self, bytes: &[u8]) -> Result<Vec<String>, ()> {
        self.pending.extend_from_slice(bytes);
        let mut out = Vec::new();
        loop {
            if self.pending.len() < 4 {
                break;
            }
            let length = u32::from_be_bytes([
                self.pending[0],
                self.pending[1],
                self.pending[2],
                self.pending[3],
            ]) as usize;
            if length > MAX_MESSAGE {
                return Err(());
            }
            if self.pending.len() < 4 + length {
                break;
            }
            let text = String::from_utf8(self.pending[4..4 + length].to_vec()).map_err(|_| ())?;
            self.pending.drain(..4 + length);
            out.push(text);
        }
        Ok(out)
    }
}
