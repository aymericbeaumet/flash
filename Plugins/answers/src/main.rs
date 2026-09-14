//! Flashlight answer engines behind one evaluator: calculator (with ECB
//! currency rates), CSS color conversions and world clocks.

mod calculator;
mod colors;
mod rates;
mod timezones;

use flash_plugin::{run, Context, EvaluateRequest, EvaluateResponse, QueryAnswer};

use calculator::Calculator;
use colors::Colors;
use timezones::Timezones;

/// The host accepts at most 16 answers per evaluator; the engines' combined
/// output is bounded here so a reply is never rejected wholesale.
const MAX_ANSWERS: usize = 16;

/// One answer engine: a synchronous, CPU-only parser over state prepared
/// earlier. Unclaimed input yields no answers.
trait Engine {
    fn answers(&self, query: &str) -> Vec<QueryAnswer>;
}

struct Answers {
    calculator: Calculator,
    timezones: Timezones,
}

impl Answers {
    fn new() -> Self {
        Self {
            calculator: Calculator::default(),
            timezones: Timezones::new(),
        }
    }

    /// Engines in the order the host ran the formerly standalone evaluators
    /// (equal priority, ids ascending): calculator, colors, timezones.
    fn engines(&self) -> [&dyn Engine; 3] {
        [&self.calculator, &Colors, &self.timezones]
    }

    fn answers(&self, query: &str) -> Vec<QueryAnswer> {
        let query = query.trim();
        // A leading `=` is the exclusive calculator marker: the host routes
        // such input to this evaluator alone, and only the calculator sees it.
        let mut answers = match query.strip_prefix('=') {
            Some(expression) => self.calculator.answers(expression.trim()),
            None => self
                .engines()
                .iter()
                .flat_map(|engine| engine.answers(query))
                .collect(),
        };
        answers.truncate(MAX_ANSWERS);
        answers
    }
}

flash_plugin::plugin!(Answers);

impl FlashPlugin for Answers {
    async fn on_start(&self, ctx: Context) {
        self.timezones.log_index(&ctx);
        self.calculator.start(ctx).await;
    }

    fn evaluate(&self, request: EvaluateRequest) -> EvaluateResponse {
        if request.surface != "flashlight" {
            return EvaluateResponse::default();
        }
        EvaluateResponse::answers(self.answers(&request.query))
    }
}

fn main() {
    run(Answers::new());
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(surface: &str, query: &str) -> EvaluateRequest {
        EvaluateRequest {
            surface: surface.to_string(),
            query: query.to_string(),
            ..EvaluateRequest::default()
        }
    }

    fn titles(answers: &[QueryAnswer]) -> Vec<&str> {
        answers.iter().map(|answer| answer.title.as_str()).collect()
    }

    #[test]
    fn equals_marker_routes_to_the_calculator_only() {
        let answers = Answers::new();
        assert_eq!(titles(&answers.answers("= 10 * 10")), ["100"]);
        assert!(answers.answers("=").is_empty());
        // Bare `time` is a world-clock query; behind `=` only the calculator
        // runs, and it declines input without a digit.
        assert!(answers.answers("= time").is_empty());
    }

    #[test]
    fn bare_input_reaches_every_engine() {
        let answers = Answers::new();
        assert_eq!(titles(&answers.answers("1+1")), ["2"]);
        assert_eq!(
            titles(&answers.answers("#ff8800")),
            ["#ff8800", "rgb(255, 136, 0)", "hsl(32, 100%, 50%)"]
        );
        let clocks = answers.answers("time in tokyo");
        assert_eq!(clocks.len(), 1, "{clocks:?}");
        assert!(clocks[0].title.ends_with("— Asia/Tokyo"), "{clocks:?}");
        assert!(answers.answers("Safari").is_empty());
    }

    #[test]
    fn non_flashlight_surfaces_are_never_claimed() {
        let answers = Answers::new();
        for query in ["1+1", "#ff8800", "time tokyo"] {
            assert!(answers.evaluate(request("other", query)).answers.is_empty());
        }
        assert_eq!(
            titles(&answers.evaluate(request("flashlight", "1+1")).answers),
            ["2"]
        );
    }
}
