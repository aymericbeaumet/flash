mod evaluator;
mod rates;

use std::collections::HashSet;
use std::sync::{Arc, RwLock};

use flash_plugin::{run, Context, EvaluateRequest, EvaluateResponse};

use rates::RatesStore;

#[derive(Default)]
struct Calculator {
    rates: RatesStore,
    target_currencies: Arc<RwLock<Vec<String>>>,
}

flash_plugin::plugin!(Calculator);

impl FlashPlugin for Calculator {
    async fn on_start(&self, ctx: Context) {
        if let Ok(mut targets) = self.target_currencies.write() {
            *targets = configured_targets(&ctx);
        }
        rates::seed_and_refresh(ctx, self.rates.clone()).await;
    }

    fn evaluate(&self, request: EvaluateRequest) -> EvaluateResponse {
        if request.surface != "flashlight" {
            return EvaluateResponse::default();
        }
        let targets = self
            .target_currencies
            .read()
            .map(|targets| targets.clone())
            .unwrap_or_default();
        EvaluateResponse::answers(evaluator::evaluate(&request.query, &self.rates, &targets))
    }
}

fn configured_targets(ctx: &Context) -> Vec<String> {
    normalize_targets(ctx.config_json::<Vec<String>>("target_currencies"))
}

fn normalize_targets(configured: Option<Vec<String>>) -> Vec<String> {
    let Some(configured) = configured else {
        return vec!["USD".to_string()];
    };
    let mut seen = HashSet::new();
    configured
        .into_iter()
        .map(|currency| currency.trim().to_ascii_uppercase())
        .filter(|currency| {
            currency.len() == 3
                && currency.bytes().all(|byte| byte.is_ascii_uppercase())
                && seen.insert(currency.clone())
        })
        .take(8)
        .collect()
}

fn main() {
    run(Calculator::default());
}

#[cfg(test)]
mod tests {
    use super::normalize_targets;

    #[test]
    fn targets_default_to_usd() {
        assert_eq!(normalize_targets(None), ["USD"]);
    }

    #[test]
    fn targets_are_normalized_deduplicated_and_bounded() {
        let configured = vec![
            " eur ".to_string(),
            "USD".to_string(),
            "eur".to_string(),
            "no".to_string(),
            "123".to_string(),
        ];
        assert_eq!(normalize_targets(Some(configured)), ["EUR", "USD"]);
    }
}
