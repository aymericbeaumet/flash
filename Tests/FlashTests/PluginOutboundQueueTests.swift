import Darwin
import Foundation
import XCTest

@testable import flash

final class PluginOutboundQueueTests: XCTestCase {
  func testInFlightFrameCanFinishAfterLifecycleClosesStdin() throws {
    let pipe = Pipe()
    let original = pipe.fileHandleForWriting
    let payload = Data("queued frame\n".utf8)
    do {
      let frame = try PluginOutboundQueue.Frame(
        data: payload, label: "event", coalescingKey: nil, handle: original,
        reservation: PluginTransportBudget.Reservation(
          generation: 1, lane: .writeFrames, bytes: payload.count))
      let independent = frame.handle.fileDescriptor != original.fileDescriptor
      XCTAssertTrue(independent, "an in-flight frame must own its descriptor across teardown")
      // An aliased Foundation handle throws an Objective-C exception after
      // close, outside Swift's error handling. Fail safely before that call.
      guard independent else { return }
      XCTAssertNotEqual(fcntl(frame.handle.fileDescriptor, F_GETFD) & FD_CLOEXEC, 0)
      XCTAssertEqual(fcntl(frame.handle.fileDescriptor, F_GETNOSIGPIPE), 1)
      try original.close()
      try frame.handle.write(contentsOf: frame.data)
    }
    // Leaving the frame retires its writer too; EOF proves it did not leak.
    XCTAssertEqual(pipe.fileHandleForReading.readDataToEndOfFile(), payload)
  }
}
