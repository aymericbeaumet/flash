import Darwin

// A test fixture for `PluginSandboxExecTests`, never shipped or spawned by
// the resident: what a process under a plugin's Seatbelt profile reads from
// the kernel. It prints one `<what> <outcome>` line per read, where the
// outcome is `read`, `markers:<found>/<asked>` or `errno:<n>`, and never
// anything it read.
//
//   hold                         wait for stdin to close (the process to read)
//   process <pid> <marker>...    the sysctl and libproc reads of one process
//   sysctl <name|n.n.n>...       one read per node, by name or by numeric MIB

private func emit(_ what: String, _ outcome: String) {
  print("\(what) \(outcome)")
}

/// The bytes of one sysctl node, nil with `errno` set when the kernel
/// refuses or the node does not exist.
private func read(mib: [Int32]) -> [UInt8]? {
  var mib = mib
  var size = 0
  guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return nil }
  // Room for a table that grew between the two calls.
  size += 16 * MemoryLayout<kinfo_proc>.stride
  var buffer = [UInt8](repeating: 0, count: size)
  guard sysctl(&mib, UInt32(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
  return Array(buffer.prefix(size))
}

/// The MIB a dotted name resolves to, with `suffix` appended.
private func resolve(_ name: String, suffix: [Int32] = []) -> [Int32]? {
  var mib = [Int32](repeating: 0, count: Int(CTL_MAXNAME))
  var count = mib.count
  guard sysctlnametomib(name, &mib, &count) == 0 else { return nil }
  return Array(mib.prefix(count)) + suffix
}

private func contains(_ haystack: [UInt8], _ needle: String) -> Bool {
  let needle = Array(needle.utf8)
  guard !needle.isEmpty, haystack.count >= needle.count else { return false }
  return (0...(haystack.count - needle.count)).contains { start in
    haystack[start..<(start + needle.count)].elementsEqual(needle)
  }
}

private func report(_ what: String, mib: [Int32]?, markers: [String]? = nil) {
  errno = 0
  guard let mib, let bytes = read(mib: mib) else {
    emit(what, "errno:\(errno)")
    return
  }
  guard let markers else {
    emit(what, "read")
    return
  }
  emit(what, "markers:\(markers.filter { contains(bytes, $0) }.count)/\(markers.count)")
}

private func probeProcess(pid: Int32, markers: [String]) {
  report("kern.procargs2", mib: [CTL_KERN, KERN_PROCARGS2, pid], markers: markers)
  report("kern.procargs", mib: [CTL_KERN, KERN_PROCARGS, pid], markers: markers)
  report("kern.proc.pid", mib: [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid])
  report("kern.proc.all", mib: [CTL_KERN, KERN_PROC, KERN_PROC_ALL])
  report("kern.proc.uid", mib: [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(getuid())])
  report("name:kern.procargs2", mib: resolve("kern.procargs2", suffix: [pid]), markers: markers)
  report("name:kern.proc.pid", mib: resolve("kern.proc.pid", suffix: [pid]))
  var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
  errno = 0
  let length = proc_pidpath(pid, &path, UInt32(path.count))
  emit("proc_pidpath", length > 0 ? "read" : "errno:\(errno)")
}

private func probeSysctl(_ nodes: [String]) {
  for node in nodes {
    let numbers = node.split(separator: ".").map { Int32($0) }
    if numbers.allSatisfy({ $0 != nil }) {
      report(node, mib: numbers.compactMap { $0 })
      continue
    }
    var size = 0
    errno = 0
    emit(node, sysctlbyname(node, nil, &size, nil, 0) == 0 ? "read" : "errno:\(errno)")
  }
}

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "hold":
  var byte: UInt8 = 0
  while Darwin.read(STDIN_FILENO, &byte, 1) > 0 {}
case "process":
  guard arguments.count >= 2, let pid = Int32(arguments[1]) else { exit(2) }
  probeProcess(pid: pid, markers: Array(arguments.dropFirst(2)))
case "sysctl":
  probeSysctl(Array(arguments.dropFirst()))
default:
  exit(2)
}
