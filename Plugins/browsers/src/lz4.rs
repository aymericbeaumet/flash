//! LZ4 *block* decoding — the payload format inside Mozilla's `mozLz40\0`
//! session-store frames. Only the block format is needed (no frame headers,
//! checksums or dictionaries), so a small bounds-checked decoder beats a
//! dependency.

/// Decode one LZ4 block into at most `expected_len` bytes. `None` for any
/// malformed input: a truncated sequence, a zero or out-of-range match
/// offset, or output that would exceed `expected_len`. The caller bounds
/// `expected_len` before calling, since it sizes the allocation.
pub fn decode_block(input: &[u8], expected_len: usize) -> Option<Vec<u8>> {
    let mut i = 0;
    let mut out = Vec::with_capacity(expected_len);
    while i < input.len() {
        let token = input[i];
        i += 1;

        let mut literal_len = (token >> 4) as usize;
        if literal_len == 15 {
            literal_len = literal_len.checked_add(read_length(input, &mut i)?)?;
        }
        let literal_end = i.checked_add(literal_len)?;
        if literal_end > input.len() || out.len().checked_add(literal_len)? > expected_len {
            return None;
        }
        out.extend_from_slice(&input[i..literal_end]);
        i = literal_end;
        // The last sequence carries literals only.
        if i >= input.len() {
            break;
        }

        if i.checked_add(2)? > input.len() {
            return None;
        }
        let offset = u16::from_le_bytes([input[i], input[i + 1]]) as usize;
        i += 2;
        if offset == 0 || offset > out.len() {
            return None;
        }

        let mut match_len = (token & 0x0f) as usize + 4;
        if (token & 0x0f) == 15 {
            match_len = match_len.checked_add(read_length(input, &mut i)?)?;
        }
        if out.len().checked_add(match_len)? > expected_len {
            return None;
        }
        // Byte-wise on purpose: a match may overlap the bytes it produces.
        for _ in 0..match_len {
            let next = out[out.len() - offset];
            out.push(next);
        }
    }
    Some(out)
}

/// LZ4's extended length: bytes of 255 accumulate until a smaller one ends it.
fn read_length(input: &[u8], i: &mut usize) -> Option<usize> {
    let mut len = 0usize;
    loop {
        let value = *input.get(*i)? as usize;
        *i += 1;
        len = len.checked_add(value)?;
        if value != 255 {
            return Some(len);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn expands_backreferences() {
        let compressed = [0x32, b'a', b'b', b'c', 3, 0];
        assert_eq!(
            decode_block(&compressed, 9).as_deref(),
            Some(&b"abcabcabc"[..])
        );
    }

    #[test]
    fn rejects_output_beyond_the_advertised_length() {
        let compressed = [0x32, b'a', b'b', b'c', 3, 0];
        assert!(decode_block(&compressed, 8).is_none());
    }

    #[test]
    fn decodes_extended_literal_lengths() {
        let literals = vec![b'x'; 300];
        // 15 + 255 + 30 = 300 literal bytes, no match (last sequence).
        let mut compressed = vec![0xf0, 255, 30];
        compressed.extend_from_slice(&literals);
        assert_eq!(decode_block(&compressed, 300), Some(literals));
    }

    #[test]
    fn rejects_truncated_and_out_of_range_input() {
        // Literal run longer than the input.
        assert!(decode_block(&[0x50, b'a'], 5).is_none());
        // Offset reaching before the start of the output.
        assert!(decode_block(&[0x10, b'a', 2, 0], 16).is_none());
        // Zero offset.
        assert!(decode_block(&[0x10, b'a', 0, 0], 16).is_none());
        // Offset cut short.
        assert!(decode_block(&[0x10, b'a', 1], 16).is_none());
    }
}
