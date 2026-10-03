import AppKit
import CFlashTerminal
import XCTest

@testable import FlashTerminal

/// Throughput instrumentation for the terminal pipeline: VT parsing, frame
/// snapshots and drawing. Every test prints `[terminal-bench]` lines and only
/// asserts that the work happened, so it stays green on loaded machines.
/// `FLASH_TERMINAL_BENCH_MB` scales the parsed workload (default 2 MiB).
final class TerminalBenchmarkTests: XCTestCase {
  private static let columns = 100
  private static let rows = 28
  private static let chunk = 32 * 1024

  private static var megabytes: Int {
    Int(ProcessInfo.processInfo.environment["FLASH_TERMINAL_BENCH_MB"] ?? "") ?? 2
  }

  private static func report(_ name: String, _ value: Double, _ unit: String) {
    print("[terminal-bench] \(name): \(String(format: "%.3f", value)) \(unit)")
  }

  private static func seconds(_ body: () -> Void) -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
  }

  /// Best of a few repetitions: concurrent load only ever adds time.
  private static func best(_ repetitions: Int = 5, _ body: () -> Double) -> Double {
    (0..<repetitions).map { _ in body() }.min() ?? 0
  }

  func testVTWriteAndSnapshotThroughput() throws {
    let workload = TerminalWorkload.bytes(megabytes: Self.megabytes, columns: Self.columns)
    let megabytes = Double(workload.count) / 1_048_576
    let parse = Self.best(3) {
      let buffer = TerminalBuffer(
        columns: Self.columns, rows: Self.rows,
        scrollbackLines: TerminalConfiguration.defaultScrollbackLines)
      return Self.seconds { TerminalWorkload.feed(workload, chunk: Self.chunk, to: buffer) }
    }
    Self.report("vt_write", megabytes / parse, "MiB/s")
    var snapshots = 0
    let framed = Self.best(3) {
      let buffer = TerminalBuffer(
        columns: Self.columns, rows: Self.rows,
        scrollbackLines: TerminalConfiguration.defaultScrollbackLines)
      snapshots = 0
      return Self.seconds {
        TerminalWorkload.feed(workload, chunk: Self.chunk, to: buffer) {
          if buffer.snapshot() != nil { snapshots += 1 }
        }
      }
    }
    XCTAssertGreaterThan(snapshots, 0)
    Self.report("vt_write+snapshot_per_32KiB", megabytes / framed, "MiB/s")
    Self.report(
      "snapshot_per_32KiB_overhead", (framed - parse) / Double(max(1, snapshots)) * 1e6, "us")
  }

  func testSnapshotCostForTypingAndFullRebuilds() throws {
    let buffer = TerminalBuffer(
      columns: Self.columns, rows: Self.rows,
      scrollbackLines: TerminalConfiguration.defaultScrollbackLines)
    buffer.write(TerminalWorkload.screen(columns: Self.columns, rows: Self.rows))
    _ = try XCTUnwrap(buffer.snapshot())
    let typing = 2000
    let incremental = Self.best {
      Self.seconds {
        for index in 0..<typing {
          buffer.write(Data([UInt8(ascii: "a") + UInt8(index % 26)]))
          _ = buffer.snapshot()
        }
      }
    }
    Self.report("snapshot_typing_one_cell", incremental / Double(typing) * 1e6, "us")
    let rebuilds = 300
    let full = Self.best {
      Self.seconds {
        for _ in 0..<rebuilds {
          buffer.invalidate()
          _ = buffer.snapshot()
        }
      }
    }
    Self.report("snapshot_full_rebuild_100x28", full / Double(rebuilds) * 1e6, "us")
  }

  func testRenderRepresentativeGridIntoBitmap() throws {
    let buffer = TerminalBuffer(
      columns: Self.columns, rows: Self.rows,
      scrollbackLines: TerminalConfiguration.defaultScrollbackLines)
    buffer.write(TerminalWorkload.screen(columns: Self.columns, rows: Self.rows))
    let frame = try XCTUnwrap(buffer.snapshot())
    let view = TerminalView(frame: .zero)
    view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)
    let cell = view.cellSize
    view.frame.size = NSSize(
      width: cell.width * CGFloat(Self.columns), height: cell.height * CGFloat(Self.rows))
    view.isRenderingEnabled = true
    view.receive(frame)
    view.displayPendingRows()
    let bitmap = try XCTUnwrap(TerminalBitmap(size: view.bounds.size, scale: 2))
    let renders = 60
    view.render(in: bitmap.context, rect: view.bounds)
    let full = Self.best {
      Self.seconds {
        for _ in 0..<renders { view.render(in: bitmap.context, rect: view.bounds) }
      }
    }
    Self.report("render_full_grid_100x28@2x", full / Double(renders) * 1e3, "ms")

    // A status-line update on the last row while the cursor sits near the top.
    buffer.write(Data("\u{1B}[\(Self.rows);1H\u{1B}[7m status 42% \u{1B}[0m\u{1B}[3;5H".utf8))
    let next = try XCTUnwrap(buffer.snapshot())
    view.receive(next)
    let damaged = view.rowsNeedingDisplay
    XCTAssertEqual(damaged, [Self.rows - 1])
    let partial = Self.best {
      Self.seconds {
        for _ in 0..<renders {
          for row in damaged {
            view.render(
              in: bitmap.context,
              rect: NSRect(
                x: 0, y: CGFloat(row) * cell.height, width: view.bounds.width, height: cell.height))
          }
        }
      }
    }
    Self.report("render_last_row_plus_cursor_rows", Double(damaged.count), "rows")
    Self.report("render_last_row_plus_cursor", partial / Double(renders) * 1e3, "ms")
  }
}

extension TerminalBenchmarkTests {
  func testCellWidthMeasurementPerCharacter() {
    let text = String(repeating: "the quick brown fox jumps over 13 lazy dogs ", count: 500)
    let characters = text.map { String($0) }
    var total = 0
    let elapsed = Self.best {
      Self.seconds {
        total = 0
        for character in characters { total += TerminalText.cellWidth(of: character) }
      }
    }
    XCTAssertEqual(total, characters.count)
    Self.report("cell_width_per_ascii_character", elapsed / Double(characters.count) * 1e9, "ns")
  }

  func testPTYSpawnToExitLatency() throws {
    let spawns = 10
    var descriptors: [Int32] = []
    let elapsed = Self.best(3) {
      Self.seconds {
        for _ in 0..<spawns {
          var child: pid_t = 0
          var failedStep: Int32 = 0
          let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
          let environment: [UnsafeMutablePointer<CChar>?] = [nil]
          let descriptor = arguments.withUnsafeBufferPointer { argv in
            environment.withUnsafeBufferPointer { env in
              flash_pty_spawn(
                "/usr/bin/true", argv.baseAddress, env.baseAddress, nil, 80, 24, &child,
                &failedStep)
            }
          }
          free(arguments[0])
          descriptors.append(descriptor)
          if descriptor >= 0 {
            var status: Int32 = 0
            waitpid(child, &status, 0)
            close(descriptor)
          }
        }
      }
    }
    XCTAssertTrue(descriptors.allSatisfy { $0 >= 0 })
    Self.report("descriptor_table_size", Double(getdtablesize()), "fds")
    Self.report("pty_spawn_to_exit", elapsed / Double(spawns) * 1e3, "ms")
  }
}

/// A flipped, device-scaled bitmap matching a layer-backed flipped view.
struct TerminalBitmap {
  let context: CGContext
  let scale: CGFloat
  let pixelWidth: Int
  let pixelHeight: Int

  init?(size: NSSize, scale: CGFloat) {
    pixelWidth = Int((size.width * scale).rounded(.up))
    pixelHeight = Int((size.height * scale).rounded(.up))
    guard pixelWidth > 0, pixelHeight > 0,
      let context = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
        bytesPerRow: pixelWidth * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
          | CGBitmapInfo.byteOrder32Little.rawValue)
    else { return nil }
    context.translateBy(x: 0, y: CGFloat(pixelHeight))
    context.scaleBy(x: scale, y: -scale)
    self.context = context
    self.scale = scale
  }

  /// Premultiplied BGRA of the pixel under a point in view coordinates.
  func pixel(x: CGFloat, y: CGFloat) -> (blue: UInt8, green: UInt8, red: UInt8, alpha: UInt8) {
    let column = min(pixelWidth - 1, max(0, Int(x * scale)))
    let row = min(pixelHeight - 1, max(0, Int(y * scale)))
    let bytes = context.data!.assumingMemoryBound(to: UInt8.self)
    let offset = row * context.bytesPerRow + column * 4
    return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
  }
}

/// Deterministic mixed terminal output: colored log lines, box-drawing
/// panels, full-screen TUI redraws, wide and combining text.
enum TerminalWorkload {
  private struct Random {
    var state: UInt64
    mutating func next(_ bound: Int) -> Int {
      state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
      return Int((state >> 33) % UInt64(bound))
    }
  }

  private static let words = [
    "request", "worker", "cache", "latency", "commit", "flash", "terminal", "render", "status",
    "popup", "session", "queue", "frame", "cells", "glyph",
  ]

  static func bytes(megabytes: Int, columns: Int) -> Data {
    var output = Data()
    var random = Random(state: 42)
    let target = max(1, megabytes) * 1_048_576
    output.reserveCapacity(target + 4096)
    while output.count < target {
      switch random.next(10) {
      case 0..<5: output.append(logLine(&random, columns: columns))
      case 5..<8: output.append(panel(&random, columns: columns))
      case 8: output.append(Data("\u{1B}[H\u{1B}[2J".utf8))
      default: output.append(unicodeLine(&random))
      }
    }
    return output
  }

  private static func logLine(_ random: inout Random, columns: Int) -> Data {
    let levels = [
      "\u{1B}[32mINFO\u{1B}[0m", "\u{1B}[33mWARN\u{1B}[0m", "\u{1B}[1;31mERROR\u{1B}[0m",
    ]
    var line =
      "2026-09-28T12:\(10 + random.next(50)):\(10 + random.next(50))Z \(levels[random.next(3)]) "
    while line.utf8.count < columns - 12 {
      line +=
        words[random.next(words.count)] + (random.next(4) == 0 ? "=\(random.next(9999)) " : " ")
    }
    return Data((line + "\r\n").utf8)
  }

  private static func panel(_ random: inout Random, columns: Int) -> Data {
    let width = min(columns, 40 + random.next(max(1, columns - 40)))
    var text = "\u{1B}[\(1 + random.next(4));\(1 + random.next(4))H"
    text +=
      "\u{1B}[38;5;\(16 + random.next(200))m┌" + String(repeating: "─", count: width - 2) + "┐\r\n"
    for _ in 0..<(4 + random.next(8)) {
      let percent = random.next(101)
      let bar =
        String(repeating: "█", count: percent / 5) + String(repeating: "░", count: 20 - percent / 5)
      let label = " \(words[random.next(words.count)]) \(percent)% "
      let body =
        label + "\u{1B}[48;2;\(random.next(80));\(random.next(80));\(random.next(80))m" + bar
      let visible = label.count + 20
      text +=
        "│\u{1B}[0m" + body + "\u{1B}[0m"
        + String(repeating: " ", count: max(0, width - 2 - visible))
        + "\u{1B}[38;5;244m│\u{1B}[K\r\n"
    }
    text += "└" + String(repeating: "─", count: width - 2) + "┘\u{1B}[0m\r\n"
    return Data(text.utf8)
  }

  private static func unicodeLine(_ random: inout Random) -> Data {
    let samples = ["日本語のテキスト", "界é", "🚀 launch", "e\u{301}cole", "👩‍💻 build", "Ünïcödé"]
    return Data(("\u{1B}[1m" + samples[random.next(samples.count)] + "\u{1B}[0m\r\n").utf8)
  }

  /// One full-screen, btop-like frame with every cell drawn.
  static func screen(columns: Int, rows: Int) -> Data {
    var random = Random(state: 7)
    var text = "\u{1B}[H\u{1B}[2J"
    for row in 0..<rows {
      text += "\u{1B}[\(row + 1);1H"
      if row == 0 || row == rows - 1 {
        text +=
          "\u{1B}[38;5;39m" + (row == 0 ? "┌" : "└") + String(repeating: "─", count: columns - 2)
          + (row == 0 ? "┐" : "┘") + "\u{1B}[0m"
        continue
      }
      var line = "\u{1B}[38;5;39m│\u{1B}[0m"
      var used = 1
      while used < columns - 12 {
        let word = words[random.next(words.count)]
        switch random.next(6) {
        case 0: line += "\u{1B}[1;32m\(word)\u{1B}[0m "
        case 1: line += "\u{1B}[38;2;200;120;\(random.next(255))m\(word)\u{1B}[0m "
        case 2: line += "\u{1B}[48;5;236m\(word)\u{1B}[0m "
        default: line += word + " "
        }
        used += word.count + 1
      }
      if row % 7 == 3 {
        line += "界面"
        used += 4
      }
      line +=
        String(repeating: " ", count: max(0, columns - 1 - used)) + "\u{1B}[38;5;39m│\u{1B}[0m"
      text += line
    }
    return Data(text.utf8)
  }

  static func feed(
    _ data: Data, chunk: Int, to buffer: TerminalBuffer, afterChunk: () -> Void = {}
  ) {
    data.withUnsafeBytes { raw in
      let bytes = raw.bindMemory(to: UInt8.self)
      var offset = 0
      while offset < bytes.count {
        let count = min(chunk, bytes.count - offset)
        buffer.write(bytes.baseAddress! + offset, count: count)
        offset += count
        afterChunk()
      }
    }
  }
}
