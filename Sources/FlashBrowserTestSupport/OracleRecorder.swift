import FlashIntegrationTestSupport
import Foundation

/// Recorder protocol for E2E assertion output.
///
/// The browser integration runner reports per-assertion pass/fail
/// lines through whatever object implements this protocol. The CLI
/// recorder prints with red/green markers and accumulates failures
/// for the exit code; an xctest recorder would forward each fail
/// to `XCTFail`. The separation lets the diff/assertion logic stay
/// agnostic of its caller.
public typealias FirefoxE2ERecorder = FlashIntegrationRecorder
