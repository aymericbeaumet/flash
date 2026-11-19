//! The keep-awake as a value: nothing held, or one hold of the power
//! assertions, bounded or not. Transitions are pure and return the effects
//! the plugin performs.

/// `caffeinate on [--minutes=N]`, `caffeinate off`,
/// `caffeinate toggle [--minutes=N]` and `caffeinate status`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Request {
    On(Option<u32>),
    Off,
    Toggle(Option<u32>),
    Status,
}

/// One hold of the power assertions.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Hold {
    /// Tells this hold from every other, so the expiry of one that was
    /// replaced or released cannot end its successor.
    pub generation: u64,
    /// How long it lasts; `None` until `caffeinate off`.
    pub seconds: Option<u64>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Effect {
    /// Release the assertions held now and cancel their expiry.
    Release,
    /// Take the assertions for the hold, and arm its expiry when it is
    /// bounded.
    Acquire(Hold),
}

#[derive(Debug, Default)]
pub struct State {
    hold: Option<Hold>,
    last_generation: u64,
}

impl State {
    pub fn is_on(&self) -> bool {
        self.hold.is_some()
    }

    pub fn hold(&self) -> Option<Hold> {
        self.hold
    }

    /// `on` replaces a hold, so a new bound counts from now; `toggle` starts
    /// one only when none is held; `off` and `status` never start one.
    pub fn apply(&mut self, request: Request) -> Vec<Effect> {
        match request {
            Request::Status => Vec::new(),
            Request::Off => self.stop(),
            Request::On(minutes) => self.start(minutes),
            Request::Toggle(_) if self.is_on() => self.stop(),
            Request::Toggle(minutes) => self.start(minutes),
        }
    }

    /// The bound of hold `generation` ran out. Nothing happens for a hold
    /// that is already gone.
    pub fn expire(&mut self, generation: u64) -> Vec<Effect> {
        if self.hold.map(|hold| hold.generation) != Some(generation) {
            return Vec::new();
        }
        self.stop()
    }

    /// Taking the assertions of hold `generation` failed: nothing is held.
    pub fn acquisition_failed(&mut self, generation: u64) {
        if self.hold.map(|hold| hold.generation) == Some(generation) {
            self.hold = None;
        }
    }

    fn start(&mut self, minutes: Option<u32>) -> Vec<Effect> {
        let mut effects = self.stop();
        self.last_generation = self.last_generation.wrapping_add(1);
        let hold = Hold {
            generation: self.last_generation,
            seconds: minutes.map(|minutes| u64::from(minutes) * 60),
        };
        self.hold = Some(hold);
        effects.push(Effect::Acquire(hold));
        effects
    }

    fn stop(&mut self) -> Vec<Effect> {
        if self.hold.take().is_some() {
            vec![Effect::Release]
        } else {
            Vec::new()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn acquired(effects: &[Effect]) -> Hold {
        match effects.last() {
            Some(Effect::Acquire(hold)) => *hold,
            other => panic!("expected an acquisition, got {other:?}"),
        }
    }

    #[test]
    fn toggle_starts_an_unbounded_hold_and_releases_it() {
        let mut state = State::default();
        assert_eq!(state.apply(Request::Status), []);
        assert_eq!(
            state.apply(Request::Off),
            [],
            "off with nothing held does nothing"
        );
        let on = state.apply(Request::Toggle(None));
        assert_eq!(on.len(), 1);
        assert_eq!(acquired(&on).seconds, None);
        assert!(state.is_on());
        assert_eq!(state.apply(Request::Status), []);
        assert_eq!(
            state.apply(Request::Toggle(Some(5))),
            [Effect::Release],
            "toggle ignores minutes to stop"
        );
        assert!(!state.is_on());
    }

    #[test]
    fn on_replaces_the_hold_so_the_new_bound_counts_from_now() {
        let mut state = State::default();
        let timed = acquired(&state.apply(Request::On(Some(5))));
        assert_eq!(timed.seconds, Some(300));
        let replaced = state.apply(Request::On(None));
        assert_eq!(replaced.len(), 2);
        assert_eq!(replaced[0], Effect::Release);
        let unbounded = acquired(&replaced);
        assert_eq!(unbounded.seconds, None);
        assert_ne!(unbounded.generation, timed.generation);
        assert_eq!(state.hold(), Some(unbounded));
    }

    /// A replaced hold's bound must not end its successor.
    #[test]
    fn only_the_current_hold_expires() {
        let mut state = State::default();
        let first = acquired(&state.apply(Request::On(Some(1))));
        let second = acquired(&state.apply(Request::On(Some(2))));
        assert_eq!(state.expire(first.generation), []);
        assert_eq!(state.hold(), Some(second));
        assert_eq!(state.expire(second.generation), [Effect::Release]);
        assert_eq!(state.hold(), None);
        assert_eq!(
            state.expire(second.generation),
            [],
            "an expired hold expires once"
        );
    }

    #[test]
    fn a_failed_acquisition_holds_nothing() {
        let mut state = State::default();
        let hold = acquired(&state.apply(Request::On(None)));
        state.acquisition_failed(hold.generation.wrapping_add(1));
        assert!(state.is_on(), "a stale failure leaves the hold alone");
        state.acquisition_failed(hold.generation);
        assert!(!state.is_on());
    }

    /// The largest `--minutes` stays far from overflowing the seconds.
    #[test]
    fn the_largest_bound_is_whole_seconds() {
        let mut state = State::default();
        let hold = acquired(&state.apply(Request::On(Some(u32::MAX))));
        assert_eq!(hold.seconds, Some(u64::from(u32::MAX) * 60));
    }
}
