//! Incremental newline framing. An oversized record is discarded before its
//! delimiter arrives; EOF never promotes a partial record into a request.

use tokio::io::{self, AsyncBufRead, AsyncBufReadExt};

#[derive(Debug, PartialEq)]
pub(crate) enum Record {
    Frame(Vec<u8>),
    Oversized,
    Truncated,
    Eof,
}

pub(crate) struct FrameReader<R> {
    input: R,
    pending: Vec<u8>,
    dropping: bool,
    limit: usize,
}

impl<R: AsyncBufRead + Unpin> FrameReader<R> {
    pub(crate) fn new(input: R, limit: usize) -> Self {
        Self {
            input,
            pending: Vec::new(),
            dropping: false,
            limit,
        }
    }

    pub(crate) async fn next(&mut self) -> io::Result<Record> {
        loop {
            let available = self.input.fill_buf().await?;
            if available.is_empty() {
                let truncated = self.dropping || !self.pending.is_empty();
                self.pending.clear();
                self.dropping = false;
                return Ok(if truncated {
                    Record::Truncated
                } else {
                    Record::Eof
                });
            }
            let newline = available.iter().position(|byte| *byte == b'\n');
            let count = newline.unwrap_or(available.len());
            let oversized = !self.dropping && count > self.limit - self.pending.len();
            if oversized {
                self.pending.clear();
                self.dropping = true;
            } else if !self.dropping {
                let needed = self.pending.len() + count;
                if needed > self.pending.capacity() {
                    let capacity = self
                        .pending
                        .capacity()
                        .max(4096)
                        .saturating_mul(2)
                        .min(self.limit)
                        .max(needed);
                    self.pending.reserve_exact(capacity - self.pending.len());
                }
                self.pending.extend_from_slice(&available[..count]);
            }
            self.input.consume(count + usize::from(newline.is_some()));
            if newline.is_some() {
                if self.dropping {
                    self.dropping = false;
                    if oversized {
                        return Ok(Record::Oversized);
                    }
                } else {
                    return Ok(Record::Frame(std::mem::take(&mut self.pending)));
                }
            }
            if oversized {
                return Ok(Record::Oversized);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::{AsyncWriteExt, BufReader};

    #[tokio::test]
    async fn limit_is_enforced_before_a_newline_and_recovers() {
        let (mut writer, input) = tokio::io::duplex(64);
        let mut reader = FrameReader::new(BufReader::with_capacity(8, input), 16);
        writer.write_all(&[b'x'; 40]).await.unwrap();
        assert_eq!(reader.next().await.unwrap(), Record::Oversized);
        assert!(reader.pending.len() <= 16);
        writer.write_all(b"\nvalid\n").await.unwrap();
        assert_eq!(
            reader.next().await.unwrap(),
            Record::Frame(b"valid".to_vec())
        );
    }

    #[tokio::test]
    async fn eof_discards_a_valid_json_fragment_without_a_newline() {
        let mut reader = FrameReader::new(&b"{\"id\":1}"[..], 16);
        assert_eq!(reader.next().await.unwrap(), Record::Truncated);
        assert_eq!(reader.next().await.unwrap(), Record::Eof);
    }

    #[tokio::test]
    async fn exact_limit_is_accepted_with_fragmented_reads() {
        let input = BufReader::with_capacity(3, &b"12345678\n\n"[..]);
        let mut reader = FrameReader::new(input, 8);
        assert_eq!(
            reader.next().await.unwrap(),
            Record::Frame(b"12345678".to_vec())
        );
        assert_eq!(reader.next().await.unwrap(), Record::Frame(Vec::new()));
        assert_eq!(reader.next().await.unwrap(), Record::Eof);
    }
}
