//! Pure CSS color query evaluator.

use flash_plugin::{run, EvaluateRequest, EvaluateResponse, QueryAnswer};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Rgb {
    r: u8,
    g: u8,
    b: u8,
}

struct Parser<'a> {
    input: &'a [u8],
    position: usize,
}

impl<'a> Parser<'a> {
    fn new(input: &'a str) -> Self {
        Self {
            input: input.as_bytes(),
            position: 0,
        }
    }

    fn is_done(&self) -> bool {
        self.position == self.input.len()
    }

    fn consume(&mut self, expected: u8) -> bool {
        if self.input.get(self.position) == Some(&expected) {
            self.position += 1;
            true
        } else {
            false
        }
    }

    fn skip_whitespace(&mut self) -> bool {
        let mut saw_literal_space = false;
        while let Some(byte) = self.input.get(self.position) {
            if !byte.is_ascii_whitespace() {
                break;
            }
            saw_literal_space |= *byte == b' ';
            self.position += 1;
        }
        saw_literal_space
    }

    /// Matches the source syntax's `\s*[, ]\s*`: either a comma or at
    /// least one literal space separates adjacent components.
    fn separator(&mut self) -> bool {
        let saw_literal_space = self.skip_whitespace();
        if self.consume(b',') {
            self.skip_whitespace();
            true
        } else {
            saw_literal_space
        }
    }

    fn integer(&mut self) -> Option<u16> {
        let start = self.position;
        while self
            .input
            .get(self.position)
            .is_some_and(u8::is_ascii_digit)
        {
            self.position += 1;
        }
        let digits = self.position - start;
        if !(1..=3).contains(&digits) {
            return None;
        }
        std::str::from_utf8(&self.input[start..self.position])
            .ok()?
            .parse()
            .ok()
    }

    fn decimal(&mut self) -> Option<f64> {
        let start = self.position;
        while self
            .input
            .get(self.position)
            .is_some_and(u8::is_ascii_digit)
        {
            self.position += 1;
        }
        let integer_digits = self.position - start;
        if !(1..=3).contains(&integer_digits) {
            return None;
        }
        if self.consume(b'.') {
            let fractional_start = self.position;
            while self
                .input
                .get(self.position)
                .is_some_and(u8::is_ascii_digit)
            {
                self.position += 1;
            }
            if self.position == fractional_start {
                return None;
            }
        }
        std::str::from_utf8(&self.input[start..self.position])
            .ok()?
            .parse()
            .ok()
    }
}

fn parse_color(input: &str) -> Option<Rgb> {
    let query = input.trim().to_ascii_lowercase();
    parse_hex(&query)
        .or_else(|| parse_rgb_function(&query))
        .or_else(|| parse_hsl_function(&query))
}

fn parse_hex(query: &str) -> Option<Rgb> {
    let digits = query.strip_prefix('#')?;
    let expanded = match digits.len() {
        3 if digits.bytes().all(|byte| byte.is_ascii_hexdigit()) => {
            let mut value = String::with_capacity(6);
            for digit in digits.chars() {
                value.push(digit);
                value.push(digit);
            }
            value
        }
        6 if digits.bytes().all(|byte| byte.is_ascii_hexdigit()) => digits.to_string(),
        _ => return None,
    };
    let value = u32::from_str_radix(&expanded, 16).ok()?;
    Some(Rgb {
        r: u8::try_from(value >> 16).ok()?,
        g: u8::try_from((value >> 8) & 0xff).ok()?,
        b: u8::try_from(value & 0xff).ok()?,
    })
}

fn parse_rgb_function(query: &str) -> Option<Rgb> {
    let inner = query.strip_prefix("rgb(")?.strip_suffix(')')?;
    let mut parser = Parser::new(inner);
    parser.skip_whitespace();
    let r = parser.integer()?;
    if !parser.separator() {
        return None;
    }
    let g = parser.integer()?;
    if !parser.separator() {
        return None;
    }
    let b = parser.integer()?;
    parser.skip_whitespace();
    if !parser.is_done() || r > 255 || g > 255 || b > 255 {
        return None;
    }
    Some(Rgb {
        r: u8::try_from(r).ok()?,
        g: u8::try_from(g).ok()?,
        b: u8::try_from(b).ok()?,
    })
}

fn parse_hsl_function(query: &str) -> Option<Rgb> {
    let inner = query.strip_prefix("hsl(")?.strip_suffix(')')?;
    let mut parser = Parser::new(inner);
    parser.skip_whitespace();
    let hue = parser.decimal()? % 360.0;
    if !parser.separator() {
        return None;
    }
    let saturation = parser.decimal()? / 100.0;
    if !parser.consume(b'%') || !parser.separator() {
        return None;
    }
    let lightness = parser.decimal()? / 100.0;
    if !parser.consume(b'%') {
        return None;
    }
    parser.skip_whitespace();
    if !parser.is_done() || saturation > 1.0 || lightness > 1.0 {
        return None;
    }
    Some(hsl_to_rgb(hue, saturation, lightness))
}

fn hsl_to_rgb(hue: f64, saturation: f64, lightness: f64) -> Rgb {
    let channel = |offset: f64| {
        let k = (offset + hue / 30.0) % 12.0;
        let a = saturation * lightness.min(1.0 - lightness);
        let scale = (k - 3.0).min(9.0 - k).clamp(-1.0, 1.0);
        ((lightness - a * scale) * 255.0).round() as u8
    };
    Rgb {
        r: channel(0.0),
        g: channel(8.0),
        b: channel(4.0),
    }
}

fn to_hsl(rgb: Rgb) -> String {
    let red = f64::from(rgb.r) / 255.0;
    let green = f64::from(rgb.g) / 255.0;
    let blue = f64::from(rgb.b) / 255.0;
    let maximum = red.max(green).max(blue);
    let minimum = red.min(green).min(blue);
    let lightness = (maximum + minimum) / 2.0;
    let delta = maximum - minimum;
    let mut hue = 0.0;
    if delta != 0.0 {
        hue = if maximum == red {
            ((green - blue) / delta) % 6.0
        } else if maximum == green {
            (blue - red) / delta + 2.0
        } else {
            (red - green) / delta + 4.0
        } * 60.0;
        if hue < 0.0 {
            hue += 360.0;
        }
    }
    let saturation = if lightness == 0.0 || lightness == 1.0 {
        0.0
    } else {
        delta / (1.0 - (2.0 * lightness - 1.0).abs())
    };
    format!(
        "hsl({}, {}%, {}%)",
        hue.round() as i64,
        (saturation * 100.0).round() as i64,
        (lightness * 100.0).round() as i64
    )
}

fn color_forms(rgb: Rgb) -> Vec<String> {
    vec![
        format!("#{:02x}{:02x}{:02x}", rgb.r, rgb.g, rgb.b),
        format!("rgb({}, {}, {})", rgb.r, rgb.g, rgb.b),
        to_hsl(rgb),
    ]
}

fn answers(query: &str) -> Vec<QueryAnswer> {
    parse_color(query)
        .map(color_forms)
        .unwrap_or_default()
        .into_iter()
        .map(|title| QueryAnswer::copy_text(title, Some("color")))
        .collect()
}

struct Colors;

flash_plugin::plugin!(Colors);

impl FlashPlugin for Colors {
    fn evaluate(&self, request: EvaluateRequest) -> EvaluateResponse {
        EvaluateResponse::answers(answers(&request.query))
    }
}

fn main() {
    run(Colors);
}

#[cfg(test)]
mod tests {
    use super::*;
    use flash_plugin::CandidateEffect;

    #[test]
    fn parses_every_supported_syntax() {
        let orange = Rgb {
            r: 255,
            g: 136,
            b: 0,
        };
        assert_eq!(parse_color(" #F80 "), Some(orange));
        assert_eq!(parse_color("rgb(255, 136, 0)"), Some(orange));
        assert_eq!(parse_color("rgb(255 136 0)"), Some(orange));
        assert_eq!(parse_color("hsl(32, 100%, 50%)"), Some(orange));
        assert_eq!(parse_color("hsl(392.0 100% 50%)"), Some(orange));
    }

    #[test]
    fn rejects_out_of_range_and_non_css_shapes() {
        for query in [
            "#ffff",
            "rgb(256, 0, 0)",
            "rgb(1\t2\t3)",
            "rgb(1, 2, 3, 4)",
            "hsl(-1, 100%, 50%)",
            "hsl(32, 101%, 50%)",
            "hsl(32, 50, 50%)",
        ] {
            assert_eq!(parse_color(query), None, "{query}");
        }
    }

    #[test]
    fn answers_keep_form_order_and_copy_effects() {
        let color_answers = answers("#ff8800");
        let titles: Vec<&str> = color_answers
            .iter()
            .map(|answer| answer.title.as_str())
            .collect();
        assert_eq!(
            titles,
            ["#ff8800", "rgb(255, 136, 0)", "hsl(32, 100%, 50%)"]
        );
        for answer in color_answers {
            assert_eq!(answer.subtitle.as_deref(), Some("color"));
            match answer.effect {
                CandidateEffect::CopyText { text } => assert_eq!(text, answer.title),
                other => panic!("unexpected effect: {other:?}"),
            }
        }
        assert!(answers("not a color").is_empty());
    }

    #[test]
    fn rgb_to_hsl_handles_achromatic_and_wrapped_hues() {
        assert_eq!(
            to_hsl(Rgb {
                r: 128,
                g: 128,
                b: 128,
            }),
            "hsl(0, 0%, 50%)"
        );
        assert_eq!(
            color_forms(Rgb { r: 0, g: 0, b: 255 }),
            ["#0000ff", "rgb(0, 0, 255)", "hsl(240, 100%, 50%)"]
        );
    }
}
