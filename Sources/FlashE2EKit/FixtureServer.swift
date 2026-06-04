import Foundation
import Network

/// Minimal localhost HTTP server that serves a single HTML body for
/// the duration of one fixture run.
///
/// Why this exists: data: URLs in Firefox MV2 don't run content
/// scripts (`<all_urls>` matches HTTP/HTTPS/FTP/file but not data:),
/// so the companion extension never mounts and FLASH_ORACLE_READY
/// never fires. Serving the fixture from http://127.0.0.1:<port>/
/// instead gives the companion a real origin to attach to.
///
/// One server per fixture run: `start(html:)` returns a URL the runner
/// hands to Firefox; `stop()` tears down after the capture.
public final class FixtureServer {
  public enum FixtureServerError: Error, CustomStringConvertible {
    case startupTimedOut
    case noPortAssigned

    public var description: String {
      switch self {
      case .startupTimedOut: return "FixtureServer never reached .ready within 5s"
      case .noPortAssigned: return "FixtureServer reached .ready but didn't expose a port"
      }
    }
  }

  private let listener: NWListener
  private let html: String
  public let port: UInt16

  public init(html: String) throws {
    self.html = html
    let listener = try NWListener(using: .tcp)
    self.listener = listener

    let portSem = DispatchSemaphore(value: 0)
    var assignedPort: UInt16 = 0
    var readyError: Error?

    listener.stateUpdateHandler = { state in
      switch state {
      case .ready:
        if let p = listener.port {
          assignedPort = p.rawValue
        } else {
          readyError = FixtureServerError.noPortAssigned
        }
        portSem.signal()
      case .failed(let err):
        readyError = err
        portSem.signal()
      default:
        break
      }
    }

    let capturedHTML = html
    listener.newConnectionHandler = { conn in
      conn.start(queue: .global(qos: .userInitiated))
      // Eat the request line (we don't route on URL — every request
      // gets the same body). Stops on Connection: close.
      conn.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { _, _, _, _ in
        let body = capturedHTML
        let bodyBytes = Array(body.utf8)
        var response = "HTTP/1.1 200 OK\r\n"
        response += "Content-Type: text/html; charset=utf-8\r\n"
        response += "Content-Length: \(bodyBytes.count)\r\n"
        response += "Cache-Control: no-store\r\n"
        response += "Connection: close\r\n"
        response += "\r\n"
        var packet = Data(response.utf8)
        packet.append(contentsOf: bodyBytes)
        conn.send(
          content: packet,
          completion: .contentProcessed { _ in conn.cancel() })
      }
    }
    listener.start(queue: .global(qos: .userInitiated))

    if portSem.wait(timeout: .now() + 5) == .timedOut {
      listener.cancel()
      throw FixtureServerError.startupTimedOut
    }
    if let err = readyError { throw err }
    self.port = assignedPort
  }

  public var url: URL {
    URL(string: "http://127.0.0.1:\(port)/")!
  }

  public func stop() {
    listener.cancel()
  }
}
