import Darwin

/// Mach absolute-time ticks, as `proc_pid_rusage` reports CPU time, to
/// nanoseconds. On Apple silicon a tick is 125/3 ns, so reading ticks as
/// nanoseconds under-reports CPU time about 42-fold.
public enum MachTime {
  private static let timebase: mach_timebase_info_data_t = {
    var info = mach_timebase_info_data_t()
    mach_timebase_info(&info)
    return info
  }()

  public static func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
    let numer = UInt64(timebase.numer)
    let denom = UInt64(max(timebase.denom, 1))
    let product = ticks.multipliedFullWidth(by: numer)
    guard product.high < denom else { return .max }
    return denom.dividingFullWidth(product).quotient
  }
}
