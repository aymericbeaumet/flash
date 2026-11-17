import FlashCore
import Foundation
import XCTest

@testable import flash

/// `[flashlight.bangs]`: the user's own bangs and quicklinks, beside the
/// plugins' bangs in the `!` list, opening a URL with the query filled in.
final class UserBangsTests: XCTestCase {
  private typealias Bang = Config.Flashlight.Bang

  func testAQueryIsPercentEncodedIntoTheTemplate() {
    let jira = "https://example.atlassian.net/browse/{query}"
    XCTAssertEqual(
      UserBangs.url(template: jira, query: "ABC-1")?.absoluteString,
      "https://example.atlassian.net/browse/ABC-1")
    XCTAssertEqual(
      UserBangs.url(template: "https://x.example/s?q={query}", query: "a b&c/é+~")?
        .absoluteString,
      "https://x.example/s?q=a%20b%26c%2F%C3%A9%2B~")
    // Every slot takes the query; none leaves an empty query out.
    XCTAssertEqual(
      UserBangs.url(template: "https://x.example/{query}/{query}", query: "k")?.absoluteString,
      "https://x.example/k/k")
    XCTAssertEqual(
      UserBangs.url(template: jira, query: "")?.absoluteString,
      "https://example.atlassian.net/browse/")
    XCTAssertEqual(UserBangs.percentEncoded("AZaz09-._~"), "AZaz09-._~")
    XCTAssertEqual(UserBangs.percentEncoded("ü ?#"), "%C3%BC%20%3F%23")
  }

  /// Without `{query}` the bang is a quicklink: the URL as written, whatever
  /// follows the bang.
  func testAQuicklinkOpensAsWritten() {
    XCTAssertEqual(
      UserBangs.url(template: "https://intranet.example.com/home", query: "anything at all")?
        .absoluteString,
      "https://intranet.example.com/home")
    XCTAssertFalse(UserBangs.takesQuery("https://intranet.example.com/home"))
    XCTAssertTrue(UserBangs.takesQuery("https://x.example/{query}"))
  }

  func testNamesAndTemplatesAreValidated() {
    for name in ["jira", "gh2", "a", "0"] {
      XCTAssertTrue(UserBangs.isValidName(name), name)
    }
    for name in ["", "Jira", "ji-ra", "ji_ra", "ji ra", "!jira", "jira!", "é"] {
      XCTAssertFalse(UserBangs.isValidName(name), name)
    }
    for template in [
      "https://x.example/{query}", "http://x.example", "https://x.example/s?q={query}&l=en",
      "https://x.example/{query}#{query}", "https://日本.example/{query}",
    ] {
      XCTAssertNil(UserBangs.templateProblem(template), template)
    }
    for template in [
      "", "ftp://x.example/{query}", "x.example/{query}", "https://", "file:///etc/hosts",
      "javascript:alert(1)", "mailto:a@x.example",
    ] {
      XCTAssertEqual(
        UserBangs.templateProblem(template), "must be an http or https URL", template)
    }
    for template in ["https://x.example/{q}", "https://x.example/{query", "https://x.example/}"] {
      XCTAssertEqual(
        UserBangs.templateProblem(template), "takes no braces but {query}", template)
    }
  }

  func testBangsListAsDeclaredRowsWithTheirDescriptionOrURL() {
    let rows = UserBangs.candidates([
      "jira": Bang(url: "https://example.atlassian.net/browse/{query}", description: "Jira"),
      "home": Bang(url: "https://intranet.example.com", description: ""),
    ])
    XCTAssertEqual(rows.map(\.title), ["!home", "!jira"])
    XCTAssertEqual(rows.map(\.sourcePayload), ["home", "jira"])
    XCTAssertEqual(rows.map(\.subtitle), ["https://intranet.example.com", "Jira"])
    XCTAssertTrue(rows.allSatisfy { $0.kind == CandidateFinder.bangKind })
    XCTAssertEqual(Set(rows.map(\.sourceID)), ["bang:user"])
    XCTAssertEqual(Set(rows.map(\.source)), ["bang"])
    XCTAssertTrue(UserBangs.candidates([:]).isEmpty)
  }

  /// The `!` list knows a user bang: a confirmed `!jira ` underlines as
  /// routable, and the index lists it among the declared bangs.
  func testTheCompletionIndexListsUserBangs() {
    let index = BangCompletionIndex(
      candidates: CoreBangs.candidates
        + UserBangs.candidates([
          "jira": Bang(url: "https://example.atlassian.net/browse/{query}", description: "")
        ]),
      precedence: .default, limit: 30)
    XCTAssertTrue(index.tokens.contains("jira"))
    XCTAssertEqual(
      index.matches(normalizedToken: "ji", precedence: .default, limit: 30).matches
        .map(\.candidate.title), ["!jira"])
  }

  /// Submitting `!jira ABC-1` opens the templated URL; a plugin's own bang
  /// and Flash's own keep their owners.
  func testSubmittingAUserBangOpensItsURL() {
    let delegate = AppDelegate()
    delegate.registry = SourceRegistry(descriptors: [], runningApplications: [])
    delegate.monitor = AppMonitor(registry: delegate.registry, config: delegate.config)
    delegate.overlay = OverlayPanel()
    defer { delegate.overlay.orderOut(nil) }
    delegate.config = ConfigLoader.parse(
      """
      [flashlight.bangs]
      jira = "https://example.atlassian.net/browse/{query}"
      home = { url = "https://intranet.example.com", description = "Intranet" }
      """)
    XCTAssertEqual(delegate.config.loadingDiagnostics.map(\.message), [])
    var opened: [URL] = []
    let opener = UserBangs.opener
    defer { UserBangs.opener = opener }
    UserBangs.opener = { opened.append($0) }
    // The session's rows are already in: a confirmed bang submits at once.
    delegate.finder.publishInitialSnapshot()

    delegate.refreshCommandLine(text: "flashlight !jira ABC-1")
    delegate.actOnSelectedCandidateFinderCandidate(submit: true)
    XCTAssertEqual(opened.map(\.absoluteString), ["https://example.atlassian.net/browse/ABC-1"])

    delegate.refreshCommandLine(text: "flashlight !home whatever")
    delegate.actOnSelectedCandidateFinderCandidate(submit: true)
    XCTAssertEqual(opened.last?.absoluteString, "https://intranet.example.com")

    // A core bang still scopes the pool instead of opening anything.
    delegate.refreshCommandLine(text: "flashlight !f report")
    delegate.finder.publishInitialSnapshot()
    delegate.actOnSelectedCandidateFinderCandidate(submit: true)
    XCTAssertEqual(opened.count, 2)
    XCTAssertEqual(delegate.overlay.commandLineText, ":flashlight !f report")
  }
}
