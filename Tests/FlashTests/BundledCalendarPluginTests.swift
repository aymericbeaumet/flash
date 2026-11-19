import AppKit
import FlashCore
import XCTest

@testable import flash

/// The built `calendar` plugin, spawned under its sandbox profile by a real
/// `PluginManager`. It holds no Calendars grant and reaches no calendar: it
/// asks the host (`host.calendar_events`), whose reader here is a stub, so
/// no test reads the Mac's calendars or shows macOS's prompt. A meeting
/// link opens through `host.open`, whose opener is this suite's.
final class BundledCalendarPluginTests: XCTestCase {
  private var manager: PluginManager!
  private var dataDir: URL!
  private var calendar: CalendarEventStub!
  private var originalOpener: ((URL) -> Bool)!
  private var originalHandler: ((URL) -> String?)!

  override func setUp() {
    originalOpener = PluginHostRPC.urlOpener
    originalHandler = PluginHostRPC.urlHandler
  }

  override func tearDown() {
    manager?.stop()
    PluginHostRPC.urlOpener = originalOpener
    PluginHostRPC.urlHandler = originalHandler
    if let dataDir { try? FileManager.default.removeItem(at: dataDir) }
  }

  private static func config(_ toml: String) throws -> Config {
    let roots = PluginRepository.officialPluginRoots()
    let root = try XCTUnwrap(roots.first { $0.lastPathComponent == "calendar" })
    let binary = root.appendingPathComponent("flash-plugin-calendar").path
    guard FileManager.default.isExecutableFile(atPath: binary) else {
      if ProcessInfo.processInfo.environment["FLASH_REQUIRE_PLUGIN_BINARIES"] == "1" {
        XCTFail("the calendar plugin must be built")
      }
      throw XCTSkip("calendar is not built: run `mise run build:plugins`")
    }
    var config = ConfigLoader.parse(toml)
    XCTAssertEqual(config.loadingDiagnostics.map(\.message), [])
    config.plugins.disabled = Set(roots.compactMap { (try? PluginManifest.load(from: $0))?.id })
      .subtracting(["calendar"])
    config.plugins.watchingEnabled = false
    return config
  }

  /// Start the plugin set under `toml` over `calendar`, wired before any
  /// plugin starts and observed as the resident observes it for a
  /// listening plugin.
  private func start(_ toml: String = "", calendar: CalendarEventStub) throws {
    let config = try Self.config(toml)
    self.calendar = calendar
    dataDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("flash-calendar-plugin-\(UUID().uuidString)")
    let manager = PluginManager(baseDataDir: dataDir)
    self.manager = manager
    let events = HostCalendarEvents(
      provider: calendar, scheduler: PollScheduler(),
      changed: { [weak manager] in manager?.emit(PluginEvent(.calendarChanged)) })
    manager.hostRPC.calendarEvents = events
    manager.start(config: config)
    waitUntilTrue("calendar loaded") { self.status != nil }
    XCTAssertTrue(manager.hasListener(for: .calendarChanged), "it holds the capability")
    CalendarChangeSource { events }.start()
  }

  private var status: PluginStatus? {
    manager.pluginStatuses().first { $0.id == "calendar" }
  }

  private func segment(_ name: String) -> String {
    status?.statusSegments[name] ?? ""
  }

  private func run(_ subcommand: String, _ args: [String] = []) -> PluginCommandResult {
    let answered = expectation(description: "calendar \(subcommand)")
    var result = PluginCommandResult.unhandled
    XCTAssertTrue(
      manager.invoke(command: "calendar", subcommand: subcommand, args: args) {
        result = $0
        answered.fulfill()
      })
    wait(for: [answered], timeout: 15)
    return result
  }

  /// An event `minutes` and a half from now: its countdown reads the next
  /// whole minute for the next half minute.
  private static func event(
    _ title: String, in minutes: Double, calendar: String = "Work", notes: String? = nil
  ) -> HostCalendarEvent {
    let start = Date().addingTimeInterval(minutes * 60 + 30)
    return HostCalendarEvent(
      id: "\(title)@\(Int(start.timeIntervalSince1970))", title: title, start: start,
      end: start.addingTimeInterval(1_800), calendar: calendar, notes: notes)
  }

  private static func clock(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
  }

  private static let bar = """
    [statusbar]
    enabled = true
    template = "#{flash.plugin.calendar.next} #{flash.plugin.calendar.next_start}"

    """

  /// Status segments nobody shows and two commands: no process, no read and
  /// no prompt until one of them is used.
  func testThePluginCostsNothingUntilItIsUsed() throws {
    let calendar = CalendarEventStub(access: .undetermined)
    try start(calendar: calendar)
    XCTAssertEqual(status?.activation, "on_demand")
    XCTAssertNil(status?.pid, "nothing runs at launch")
    XCTAssertNil(manager.ownCommandConfirmation(command: "calendar", subcommand: "join"))
    settleRunLoop(0.2)
    XCTAssertEqual(calendar.asks, 0)
    XCTAssertEqual(calendar.reads, 0)
    // An argument is refused before anything is read.
    XCTAssertEqual(
      run("next", ["--now"]), PluginCommandResult(ok: false, error: "usage: calendar next"))
    XCTAssertNotNil(status?.pid, "the first command spawned it")
    XCTAssertEqual(calendar.asks, 0)
    XCTAssertEqual(calendar.reads, 0)
  }

  /// The sandbox proof: under the plugin's own profile, a shown value is
  /// read through the host, the event's start is told in the Mac's own time
  /// zone, and a calendar change is read again.
  func testAShownValueIsReadThroughTheHostAndFollowsTheCalendar() throws {
    let standup = Self.event("Standup", in: 12)
    let calendar = CalendarEventStub(access: .granted, events: [standup])
    try start(
      Self.bar + """
        [plugins.calendar]
        calendars = ["Work"]
        lookahead_hours = 2
        """, calendar: calendar)
    XCTAssertEqual(status?.activation, "resident", "its values are shown")
    waitUntilTrue("the next meeting was published") { self.segment("next") == "Standup in 13m" }
    XCTAssertEqual(segment("next_title"), "Standup")
    XCTAssertEqual(segment("next_minutes"), "13")
    XCTAssertEqual(segment("next_ongoing"), "")
    XCTAssertEqual(segment("next_link"), "")
    // Local time, computed inside the sandbox.
    XCTAssertEqual(segment("next_start"), Self.clock(standup.start))
    XCTAssertEqual(segment("next_end"), Self.clock(standup.end))
    XCTAssertEqual(calendar.asks, 0)
    XCTAssertEqual(calendar.calendars, [["Work"]])
    let range = try XCTUnwrap(calendar.ranges.first)
    XCTAssertEqual(
      range.upperBound.timeIntervalSince(range.lowerBound), 4 * 3_600, "twice the look-ahead")
    XCTAssertLessThan(abs(range.lowerBound.timeIntervalSinceNow), 30)
    XCTAssertFalse(calendar.calledOnMain)

    // The calendar changes: one announcement, one more read.
    calendar.events = .events([
      Self.event("Review", in: 5, notes: "Join: https://meet.google.com/abc-defg-hij."), standup,
    ])
    calendar.change()
    waitUntilTrue("the change was read") { self.segment("next") == "Review in 6m" }
    XCTAssertEqual(segment("next_link"), "https://meet.google.com/abc-defg-hij")
    XCTAssertEqual(calendar.reads, 2)
  }

  /// Showing a value is the user's own use of the plugin: its first read
  /// asks macOS when Flash never did, once, and the values follow.
  func testTheFirstShownValueAsksOnce() throws {
    let calendar = CalendarEventStub(
      access: .undetermined, events: [Self.event("Standup", in: 12)])
    try start(Self.bar, calendar: calendar)
    waitUntilTrue("asked, granted and read") { self.segment("next") == "Standup in 13m" }
    XCTAssertEqual(calendar.asks, 1)
    XCTAssertEqual(
      run("next").message?.hasPrefix("Standup in 13m · "), true, "a command reads without asking")
    XCTAssertEqual(calendar.asks, 1)
  }

  func testNextAnswersWithTheAlertAndAsksFromACommand() throws {
    let standup = Self.event("Standup", in: 12, notes: "https://zoom.us/j/123?pwd=abc")
    let calendar = CalendarEventStub(access: .undetermined, events: [standup])
    try start(calendar: calendar)
    let detail = "in 13m · \(Self.clock(standup.start))–\(Self.clock(standup.end)) · Zoom"
    XCTAssertEqual(
      run("next"),
      PluginCommandResult(
        ok: true, message: "Standup \(detail)",
        alert: PluginAlert(title: "Standup", value: detail)))
    XCTAssertEqual(calendar.asks, 1, "a command is the user's own use: it may ask")
    XCTAssertEqual(manager.catalogStore.publishedPluginIDs(), [])

    calendar.events = .events([])
    let none = run("next")
    XCTAssertEqual(none, PluginCommandResult(ok: false, error: "No event in the next 24 hours"))
    XCTAssertEqual(none.failureAlert, none.error, "short enough to show")
  }

  func testARefusedCalendarSaysWhereToAllowIt() throws {
    let calendar = CalendarEventStub(
      access: .undetermined, grants: false, events: [Self.event("Standup", in: 12)])
    try start(calendar: calendar)
    let refused = run("join")
    XCTAssertEqual(
      refused.error,
      "Flash may not read your calendars: allow it in System Settings › Privacy & Security › "
        + "Calendars")
    XCTAssertEqual(refused.failureAlert, refused.error, "short enough to show")
    XCTAssertEqual(run("next").error, refused.error)
    XCTAssertEqual(calendar.asks, 1, "refused once, never asked again")
    XCTAssertEqual(calendar.reads, 0)
  }

  /// `calendar join` opens the meeting in its app when one handles its
  /// link, else the link itself, through the host.
  func testJoinOpensTheMeetingThroughTheHost() throws {
    var opened: [URL] = []
    var zoomInstalled = true
    PluginHostRPC.urlOpener = { url in
      opened.append(url)
      return true
    }
    PluginHostRPC.urlHandler = { url in
      url.scheme == "zoommtg" ? (zoomInstalled ? "us.zoom.xos" : nil) : "com.apple.Safari"
    }
    let calendar = CalendarEventStub(
      access: .granted,
      events: [
        Self.event("Standup", in: 2, notes: "Join Zoom Meeting (https://zoom.us/j/123?pwd=abc).")
      ])
    try start(calendar: calendar)
    XCTAssertEqual(run("join"), PluginCommandResult(ok: true, message: "Joining Standup"))
    XCTAssertEqual(
      opened, [URL(string: "zoommtg://zoom.us/join?action=join&confno=123&pwd=abc")])

    zoomInstalled = false
    XCTAssertEqual(run("join").message, "Joining Standup")
    XCTAssertEqual(opened.last, URL(string: "https://zoom.us/j/123?pwd=abc"))
    XCTAssertEqual(opened.count, 2, "the app's link was never handed over")

    // An event without a link says so, and names no event: the host logs a
    // failure's reason.
    calendar.events = .events([Self.event("Lunch", in: 30)])
    XCTAssertEqual(
      run("join"), PluginCommandResult(ok: false, error: "The event has no meeting link"))
    XCTAssertEqual(opened.count, 2)
  }
}
