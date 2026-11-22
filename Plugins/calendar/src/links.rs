//! Meeting links: which of an event's links joins its meeting, of which
//! service, and the same meeting as its app opens it. Pure.
//!
//! The host hands over an event's URL field, its location and the
//! link-shaped runs of its notes (never the notes themselves); which of
//! them is a meeting is decided here.

use std::sync::OnceLock;

use regex_lite::Regex;

/// An event's meeting link, found in its URL, location or notes.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct MeetingLink {
    /// The service, as `calendar next` names it: `Zoom`, `Google Meet`, or
    /// the host of a link no service claims.
    pub(crate) service: String,
    /// The link as the event writes it.
    pub(crate) url: String,
    /// The same meeting in its app (`zoommtg:`, `msteams:`): `calendar join`
    /// opens it when an app handles it, and `url` otherwise.
    pub(crate) app_url: Option<String>,
}

struct Service {
    name: &'static str,
    pattern: Regex,
    /// A match the pattern takes and the service does not.
    refuses: fn(&str) -> bool,
    app_url: fn(&str) -> Option<String>,
}

/// What a link runs to: never whitespace, a quote or the brackets that wrap
/// one in text or HTML.
const BODY: &str = r#"[^\s<>"'()\[\]{}]+"#;

fn service(name: &'static str, pattern: &str) -> Service {
    Service {
        name,
        // The patterns are constants; a broken one fails every test that
        // finds a link.
        pattern: Regex::new(&format!("(?i){pattern}")).expect("a constant pattern"),
        refuses: |_| false,
        app_url: |_| None,
    }
}

/// Zoom, Google Meet, Microsoft Teams, Webex, Around, Whereby, FaceTime,
/// Slack huddles, Jitsi Meet, GoTo Meeting and Amazon Chime, in order of
/// preference when two match at the same place.
fn services() -> &'static [Service] {
    static SERVICES: OnceLock<Vec<Service>> = OnceLock::new();
    SERVICES.get_or_init(|| {
        let body = BODY;
        vec![
            Service {
                app_url: zoom_app_url,
                ..service(
                    "Zoom",
                    &format!(
                        r"https?://(?:[a-z0-9-]+\.)*zoom(?:gov)?\.(?:us|com)/(?:j|my|w|s|wc/join)/{body}"
                    ),
                )
            },
            service("Zoom", &format!(r"zoom(?:mtg|us)://{body}")),
            service(
                "Google Meet",
                &format!(r"https?://meet\.google\.com/(?:lookup/)?[a-z0-9_-]+(?:\?{body})?"),
            ),
            Service {
                app_url: teams_app_url,
                ..service(
                    "Microsoft Teams",
                    &format!(
                        r"https?://teams\.(?:microsoft|live)\.com/(?:l/meetup-join|meet|v2)/{body}"
                    ),
                )
            },
            service("Microsoft Teams", &format!(r"msteams:/{body}")),
            Service {
                // Webex's help pages and its site are no meeting.
                refuses: |link| {
                    let host = link.split_once("://").map_or("", |(_, rest)| rest);
                    let host = host.to_ascii_lowercase();
                    host.starts_with("help.") || host.starts_with("www.")
                },
                ..service(
                    "Webex",
                    &format!(r"https?://(?:[a-z0-9-]+\.)+webex\.com/{body}"),
                )
            },
            service("Around", &format!(r"https?://(?:meet\.)?around\.co/{body}")),
            service(
                "Whereby",
                &format!(r"https?://(?:[a-z0-9-]+\.)?whereby\.com/{body}"),
            ),
            service(
                "FaceTime",
                &format!(r"https?://facetime\.apple\.com/join{body}"),
            ),
            service("FaceTime", &format!(r"facetime(?:-audio)?://{body}")),
            service(
                "Slack huddle",
                &format!(r"https?://app\.slack\.com/huddle/{body}"),
            ),
            service("Jitsi Meet", &format!(r"https?://meet\.jit\.si/{body}")),
            service(
                "GoTo Meeting",
                &format!(
                    r"https?://(?:(?:global|www)\.gotomeeting\.com/join|meet\.goto\.com|(?:www\.)?gotomeet\.me)/{body}"
                ),
            ),
            service("Amazon Chime", &format!(r"https?://chime\.aws/{body}")),
        ]
    })
}

/// The event's meeting link: a service's link in its URL, else in its
/// location, else in its notes' links, the earliest in each; else its URL or
/// a location that is one web link, as a meeting no service claims.
pub(crate) fn find(
    url: Option<&str>,
    location: Option<&str>,
    notes_links: &[String],
) -> Option<MeetingLink> {
    // The runs came out of the notes one after another: a line each keeps
    // their order and never joins two.
    let notes = notes_links.join("\n");
    let notes = (!notes.is_empty()).then_some(notes.as_str());
    for text in [url, location, notes].into_iter().flatten() {
        if let Some(link) = find_in(text) {
            return Some(link);
        }
    }
    if let Some(url) = url
        && is_web(url)
    {
        return Some(generic(url));
    }
    let location = location?.trim();
    if !location.is_empty()
        && !location.contains(char::is_whitespace)
        && is_web(location)
        && host(location).is_some()
    {
        return Some(generic(location));
    }
    None
}

/// The earliest service link in `text`.
pub(crate) fn find_in(text: &str) -> Option<MeetingLink> {
    // The patterns read ASCII whitespace; a link ends at any.
    let text: String = text
        .chars()
        .map(|character| {
            if character.is_whitespace() {
                ' '
            } else {
                character
            }
        })
        .collect();
    let mut best: Option<(usize, MeetingLink)> = None;
    for service in services() {
        let Some((start, matched)) = first_match(service, &text) else {
            continue;
        };
        if best
            .as_ref()
            .is_some_and(|(earliest, _)| start >= *earliest)
        {
            continue;
        }
        let url = cleaned(matched);
        best = Some((
            start,
            MeetingLink {
                service: service.name.to_string(),
                app_url: (service.app_url)(&url),
                url,
            },
        ));
    }
    best.map(|(_, link)| link)
}

/// Where the service's first link starts in `text`, and the link.
fn first_match<'a>(service: &Service, text: &'a str) -> Option<(usize, &'a str)> {
    let mut from = 0;
    while from <= text.len() {
        let found = service.pattern.find_at(text, from)?;
        if !(service.refuses)(found.as_str()) {
            return Some((found.start(), found.as_str()));
        }
        // The next place a link may start: past this one's first character.
        from = found.start()
            + text[found.start()..]
                .chars()
                .next()
                .map_or(1, char::len_utf8);
    }
    None
}

/// A link as written in HTML notes, without the punctuation that ends the
/// sentence around it.
fn cleaned(link: &str) -> String {
    link.replace("&amp;", "&")
        .trim_end_matches(['.', ',', ';', ':', '!', '?'])
        .to_string()
}

/// The URL's scheme, lowercased: letters, digits, `+`, `-` and `.` before
/// the first `:`, starting with a letter.
fn scheme(url: &str) -> Option<String> {
    let (scheme, _) = url.split_once(':')?;
    let mut characters = scheme.chars();
    let valid = characters.next().is_some_and(|c| c.is_ascii_alphabetic())
        && characters.all(|c| c.is_ascii_alphanumeric() || "+-.".contains(c));
    valid.then(|| scheme.to_ascii_lowercase())
}

fn is_web(url: &str) -> bool {
    matches!(scheme(url).as_deref(), Some("http" | "https"))
}

/// What follows the scheme's `//`: the authority, and the rest from its
/// path on.
fn authority(url: &str) -> Option<(&str, &str)> {
    let (_, rest) = url.split_once("://")?;
    let end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    Some(rest.split_at(end))
}

/// The URL's host as written, without user info or port; `None` without one.
fn host(url: &str) -> Option<&str> {
    let (authority, _) = authority(url)?;
    let host = authority
        .rsplit_once('@')
        .map_or(authority, |(_, host)| host);
    let host = match host.rsplit_once(':') {
        Some((name, port)) if port.bytes().all(|b| b.is_ascii_digit()) => name,
        _ => host,
    };
    (!host.is_empty()).then_some(host)
}

/// A web link no service claims, named by its host.
fn generic(url: &str) -> MeetingLink {
    let mut service = host(url).unwrap_or(url);
    if service
        .get(..4)
        .is_some_and(|prefix| prefix.eq_ignore_ascii_case("www."))
    {
        service = &service[4..];
    }
    MeetingLink {
        service: service.to_string(),
        url: url.to_string(),
        app_url: None,
    }
}

/// `https://<host>/j/<id>?pwd=<pwd>` as Zoom's own `zoommtg:` join link.
fn zoom_app_url(url: &str) -> Option<String> {
    let host = host(url)?;
    let (_, rest) = authority(url)?;
    let rest = rest.split_once('#').map_or(rest, |(rest, _)| rest);
    let (path, query) = rest.split_once('?').unwrap_or((rest, ""));
    let mut segments = path.split('/').filter(|segment| !segment.is_empty());
    let (Some("j"), Some(id), None) = (segments.next(), segments.next(), segments.next()) else {
        return None;
    };
    if !id.chars().all(char::is_numeric) {
        return None;
    }
    let mut app = format!("zoommtg://{host}/join?action=join&confno={id}");
    for pair in query.split('&') {
        if let Some(password) = pair.strip_prefix("pwd=") {
            app.push_str("&pwd=");
            app.push_str(password);
        } else if pair == "pwd" {
            app.push_str("&pwd");
        }
    }
    Some(app)
}

/// A Teams web link as Teams' own `msteams:` link.
fn teams_app_url(url: &str) -> Option<String> {
    let (_, rest) = url.split_once(':')?;
    Some(format!("msteams:{rest}"))
}

#[cfg(test)]
pub(crate) mod testing {
    use super::MeetingLink;

    pub(crate) fn zoom() -> MeetingLink {
        MeetingLink {
            service: "Zoom".into(),
            url: "https://zoom.us/j/123".into(),
            app_url: Some("zoommtg://zoom.us/join?action=join&confno=123".into()),
        }
    }

    pub(crate) fn meet() -> MeetingLink {
        MeetingLink {
            service: "Google Meet".into(),
            url: "https://meet.google.com/abc-defg-hij".into(),
            app_url: None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A link in notes the host scanned: its link-shaped runs, as
    /// `HostCalendarEvents.linkRuns` cuts them.
    fn runs(notes: &str) -> Vec<String> {
        let run = Regex::new(&format!("(?i)[a-z][a-z0-9+.-]*:/{BODY}")).unwrap();
        run.find_iter(notes)
            .map(|found| found.as_str().to_string())
            .collect()
    }

    fn link(url: Option<&str>, location: Option<&str>, notes: Option<&str>) -> Option<MeetingLink> {
        find(url, location, &notes.map(runs).unwrap_or_default())
    }

    fn in_notes(notes: &str) -> Option<MeetingLink> {
        link(None, None, Some(notes))
    }

    #[test]
    fn every_service_is_found() {
        let cases = [
            ("https://us02web.zoom.us/j/85748372?pwd=abc", "Zoom"),
            ("zoommtg://zoom.us/join?confno=1", "Zoom"),
            ("https://meet.google.com/abc-defg-hij", "Google Meet"),
            (
                "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7b%7d",
                "Microsoft Teams",
            ),
            ("https://teams.live.com/meet/9387", "Microsoft Teams"),
            ("https://acme.webex.com/acme/j.php?MTID=m1", "Webex"),
            ("https://around.co/r/standup", "Around"),
            ("https://whereby.com/team-room", "Whereby"),
            (
                "https://facetime.apple.com/join#v=1&p=AbC&k=dEf",
                "FaceTime",
            ),
            ("https://app.slack.com/huddle/T0123/C0456", "Slack huddle"),
            ("https://meet.jit.si/FlashStandup", "Jitsi Meet"),
            (
                "https://global.gotomeeting.com/join/123456789",
                "GoTo Meeting",
            ),
            ("https://chime.aws/1234567890", "Amazon Chime"),
        ];
        for (url, service) in cases {
            let found = in_notes(&format!("Join: {url}\nThanks"));
            assert_eq!(
                found.as_ref().map(|l| l.service.as_str()),
                Some(service),
                "{url}"
            );
            assert_eq!(found.map(|l| l.url), Some(url.to_string()), "{url}");
        }
        for (url, service) in [
            ("msteams:/l/meetup-join/19%3am/0", "Microsoft Teams"),
            ("facetime-audio://user@example.com", "FaceTime"),
            ("HTTPS://ZOOM.US/J/123", "Zoom"),
        ] {
            assert_eq!(
                in_notes(url).map(|l| l.service),
                Some(service.to_string()),
                "{url}"
            );
        }
    }

    #[test]
    fn the_join_link_is_the_first_one_and_its_sentence_punctuation_is_dropped() {
        let zoom = in_notes(
            "Find your local number: https://us02web.zoom.us/u/kdLx\n\
             Join Zoom Meeting (https://us02web.zoom.us/j/857?pwd=x&amp;uname=a).\n\
             Or https://meet.google.com/abc-defg-hij.",
        )
        .unwrap();
        assert_eq!(zoom.service, "Zoom");
        assert_eq!(zoom.url, "https://us02web.zoom.us/j/857?pwd=x&uname=a");
        assert_eq!(
            in_notes("<a href=\"https://meet.google.com/abc-defg-hij\">Join</a>").map(|l| l.url),
            Some("https://meet.google.com/abc-defg-hij".to_string())
        );
        // The earliest link wins, whichever service is listed first.
        assert_eq!(
            in_notes("https://meet.google.com/abc-defg-hij then https://zoom.us/j/1")
                .map(|l| l.service),
            Some("Google Meet".to_string())
        );
        // Webex's help pages are no meeting, and a meeting after them is.
        assert_eq!(
            in_notes("Help: https://help.webex.com/docs then https://www.webex.com/x"),
            None
        );
        assert_eq!(
            in_notes("https://help.webex.com/x?u=https://acme.webex.com/meet/a").map(|l| l.url),
            Some("https://acme.webex.com/meet/a".to_string())
        );
        assert_eq!(in_notes("Agenda at https://example.com/agenda"), None);
        assert_eq!(in_notes(""), None);
    }

    #[test]
    fn the_url_then_the_location_then_the_notes_are_read() {
        let all = link(
            Some("https://meet.google.com/aaa-bbbb-ccc"),
            Some("https://zoom.us/j/1"),
            Some("https://teams.live.com/meet/1"),
        );
        assert_eq!(all.map(|l| l.service), Some("Google Meet".to_string()));
        assert_eq!(
            link(
                None,
                Some("Room 4 / https://zoom.us/j/1"),
                Some("https://teams.live.com/meet/1")
            )
            .map(|l| l.service),
            Some("Zoom".to_string())
        );
        // A no-break space ends a link in a location as a space does.
        assert_eq!(
            link(None, Some("https://zoom.us/j/1\u{a0}Room 4"), None).map(|l| l.url),
            Some("https://zoom.us/j/1".to_string())
        );
        // A URL or a location that is one web link is a meeting no service
        // claims.
        assert_eq!(
            link(
                Some("https://meet.acme.com/standup"),
                None,
                Some("https://zoom.us/j/1")
            )
            .map(|l| l.service),
            Some("Zoom".to_string())
        );
        let generic = link(Some("https://www.meet.acme.com/standup"), None, None).unwrap();
        assert_eq!(generic.service, "meet.acme.com");
        assert_eq!(generic.url, "https://www.meet.acme.com/standup");
        assert_eq!(generic.app_url, None);
        assert_eq!(
            link(None, Some(" https://rooms.acme.com:8443/4\n"), None),
            Some(MeetingLink {
                service: "rooms.acme.com".into(),
                url: "https://rooms.acme.com:8443/4".into(),
                app_url: None
            })
        );
        assert_eq!(
            link(None, Some("Room 4, https://rooms.acme.com/4"), None),
            None
        );
        assert_eq!(link(Some("mailto:a@b.c"), Some("Paris"), None), None);
        assert_eq!(link(None, Some("https://"), None), None);
        assert_eq!(link(None, None, None), None);
    }

    /// `calendar join` opens the meeting in its app when one handles it.
    #[test]
    fn zoom_and_teams_links_have_their_apps_links() {
        let app = |notes: &str| in_notes(notes).and_then(|l| l.app_url);
        assert_eq!(
            app("https://acme.zoom.us/j/857?pwd=x1&uname=a"),
            Some("zoommtg://acme.zoom.us/join?action=join&confno=857&pwd=x1".to_string())
        );
        assert_eq!(
            app("https://zoom.us/j/857"),
            Some("zoommtg://zoom.us/join?action=join&confno=857".to_string())
        );
        assert_eq!(
            app("https://zoom.us/j/857#success"),
            Some("zoommtg://zoom.us/join?action=join&confno=857".to_string())
        );
        assert_eq!(app("https://zoom.us/my/alice"), None);
        assert_eq!(app("https://zoom.us/j/857/extra"), None);
        assert_eq!(
            app("https://teams.microsoft.com/l/meetup-join/19%3am/0"),
            Some("msteams://teams.microsoft.com/l/meetup-join/19%3am/0".to_string())
        );
        assert_eq!(app("https://meet.google.com/abc-defg-hij"), None);
        assert_eq!(testing::zoom(), in_notes("https://zoom.us/j/123").unwrap());
        assert_eq!(
            testing::meet(),
            in_notes("https://meet.google.com/abc-defg-hij").unwrap()
        );
    }
}
