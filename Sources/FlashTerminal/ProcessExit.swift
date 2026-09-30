import CFlashTerminal
import Darwin
import Dispatch

/// Waits for processes on the kernel's exit events (kqueue `NOTE_EXIT`),
/// never on a sleep loop: a wait ends the moment the last process it waits
/// for exits, or at its deadline.
///
/// An exit is reported a moment before the process becomes a zombie. A pid
/// whose exit was reported is never registered again, and a child whose
/// exit was reported is reaped with `reap`, which waits out that moment.
public enum ProcessExit {
  /// Reap child `pid` once its exit was reported, returning its status as a
  /// shell reports it (exit code, or 128 + signal); nil when there is nothing
  /// to reap (`ECHILD`).
  public static func reap(_ pid: pid_t) -> Int32? {
    var status: Int32 = 0
    return flash_pty_reap(pid, &status) == pid ? status : nil
  }

  /// Reap child `pid` as soon as the kernel reports its exit, with no thread
  /// waiting meanwhile, then run `completion` on the reaper queue. A child
  /// already a zombie is reaped at once.
  public static func reapWhenExited(_ pid: pid_t, completion: @escaping () -> Void = {}) {
    let source = DispatchSource.makeProcessSource(
      identifier: pid, eventMask: .exit, queue: reaperQueue)
    var finished = false
    let finish = {
      guard !finished else { return }
      finished = true
      // Cancelling releases the handler, and with it this closure's hold on
      // the source.
      source.cancel()
      _ = reap(pid)
      completion()
    }
    source.setEventHandler(handler: finish)
    source.resume()
    reaperQueue.async {
      var status: Int32 = 0
      let result = flash_pty_wait(pid, &status)
      if result == pid || (result < 0 && errno == ECHILD) { finish() }
    }
  }

  /// Block until `pid` exits or `deadline` passes; true when it exited (or
  /// was already gone).
  public static func waitForExit(_ pid: pid_t, until deadline: DispatchTime) -> Bool {
    var exited: Set<pid_t> = []
    return waitForAll([pid], until: deadline, exited: &exited)
  }

  /// Block until every live member of each process group (the leaders
  /// included) has exited or `deadline` passes; true when all are gone.
  /// `exited` collects every pid whose exit was reported, so a caller knows
  /// which leaders to `reap`. Members are listed again after each exit, so a
  /// group's late forks are waited for too.
  public static func waitForGroups(
    _ groups: [pid_t], until deadline: DispatchTime, exited: inout Set<pid_t>
  ) -> Bool {
    while true {
      let live = groups.flatMap(members(ofGroup:)).filter { !exited.contains($0) }
      guard !live.isEmpty else { return true }
      let before = exited.count
      if waitForAll(live, until: deadline, exited: &exited) { continue }
      guard exited.count > before else { return false }
    }
  }

  /// Every process in group `pgid`, zombies included.
  public static func members(ofGroup pgid: pid_t) -> [pid_t] {
    let estimate = proc_listpgrppids(pgid, nil, 0)
    guard estimate > 0 else { return [] }
    let capacity = Int(estimate) + 16
    var pids = [pid_t](repeating: 0, count: capacity)
    let filled = proc_listpgrppids(pgid, &pids, Int32(capacity * MemoryLayout<pid_t>.size))
    guard filled > 0 else { return [] }
    return pids.prefix(Int(filled)).filter { $0 > 0 }
  }

  private static let reaperQueue = DispatchQueue(
    label: "com.flash.process.reaper", qos: .utility)

  /// Register every pid for its exit event and wait until all of them
  /// exited (true) or the deadline passed (false). A pid that cannot be
  /// registered because it is already gone counts as exited.
  private static func waitForAll(
    _ pids: [pid_t], until deadline: DispatchTime, exited: inout Set<pid_t>
  ) -> Bool {
    let pending = Set(pids).subtracting(exited)
    guard !pending.isEmpty else { return true }
    let queue = kqueue()
    guard queue >= 0 else { return false }
    defer { close(queue) }
    var changes = pending.map { pid in
      Darwin.kevent(
        ident: UInt(pid), filter: Int16(EVFILT_PROC),
        flags: UInt16(EV_ADD | EV_ONESHOT | EV_RECEIPT), fflags: UInt32(NOTE_EXIT), data: 0,
        udata: nil)
    }
    // With EV_RECEIPT every change answers with its own EV_ERROR entry:
    // data 0 when registered, ESRCH when the process is already gone.
    var receipts = Array(repeating: Darwin.kevent(), count: changes.count)
    let answered = kevent(
      queue, &changes, Int32(changes.count), &receipts, Int32(receipts.count), nil)
    var waiting = pending
    for receipt in receipts.prefix(Int(max(0, answered)))
    where receipt.flags & UInt16(EV_ERROR) != 0 && receipt.data != 0 {
      waiting.remove(pid_t(receipt.ident))
      exited.insert(pid_t(receipt.ident))
    }
    var events = Array(repeating: Darwin.kevent(), count: waiting.count)
    while !waiting.isEmpty {
      let now = DispatchTime.now().uptimeNanoseconds
      guard now < deadline.uptimeNanoseconds else { return false }
      let remaining = deadline.uptimeNanoseconds - now
      var timeout = timespec(
        tv_sec: Int(remaining / 1_000_000_000), tv_nsec: Int(remaining % 1_000_000_000))
      let count = kevent(queue, nil, 0, &events, Int32(events.count), &timeout)
      if count < 0, errno == EINTR { continue }
      guard count > 0 else { return false }
      for event in events.prefix(Int(count)) where event.filter == Int16(EVFILT_PROC) {
        waiting.remove(pid_t(event.ident))
        exited.insert(pid_t(event.ident))
      }
    }
    return true
  }
}
