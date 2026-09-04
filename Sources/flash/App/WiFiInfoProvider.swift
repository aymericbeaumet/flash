import CoreLocation
import CoreWLAN
import Foundation

protocol WiFiInfoProviding: AnyObject {
  func fetchSSID(_ completion: @escaping (String?) -> Void)
}

/// Owns the host's Location authorization request for the narrow purpose of
/// reading the current Wi-Fi SSID. CoreLocation never receives location
/// updates; it is used only for the permission CoreWLAN requires.
final class WiFiInfoProvider: NSObject, WiFiInfoProviding, CLLocationManagerDelegate {
  private typealias Completion = (String?) -> Void

  private let locationManager: CLLocationManager?
  private let authorizationStatus: () -> CLAuthorizationStatus
  private let requestAuthorization: () -> Void
  private let readSSID: () -> String?
  private var didRequestAuthorization = false
  private var pending: [Completion] = []

  override init() {
    let manager = CLLocationManager()
    locationManager = manager
    authorizationStatus = { manager.authorizationStatus }
    requestAuthorization = { manager.requestWhenInUseAuthorization() }
    readSSID = {
      CWWiFiClient.shared().interface(withName: nil)?.ssid()
    }
    super.init()
    manager.delegate = self
  }

  init(
    authorizationStatus: @escaping () -> CLAuthorizationStatus,
    requestAuthorization: @escaping () -> Void,
    readSSID: @escaping () -> String?
  ) {
    locationManager = nil
    self.authorizationStatus = authorizationStatus
    self.requestAuthorization = requestAuthorization
    self.readSSID = readSSID
    super.init()
  }

  func fetchSSID(_ completion: @escaping (String?) -> Void) {
    onMain { [self] in
      resolveOrRequest(completion)
    }
  }

  func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    authorizationDidChange()
  }

  /// Internal so the authorization state machine can be driven without a real
  /// CLLocationManager or system prompt in tests.
  func authorizationDidChange() {
    onMain { [self] in
      resolvePendingIfDetermined()
    }
  }

  private func resolveOrRequest(_ completion: @escaping Completion) {
    dispatchPrecondition(condition: .onQueue(.main))
    switch authorizationStatus() {
    case .authorizedAlways:
      completion(currentSSID())
    case .notDetermined:
      pending.append(completion)
      guard !didRequestAuthorization else { return }
      didRequestAuthorization = true
      requestAuthorization()
    case .denied, .restricted:
      completion(nil)
    @unknown default:
      completion(nil)
    }
  }

  private func resolvePendingIfDetermined() {
    dispatchPrecondition(condition: .onQueue(.main))
    let status = authorizationStatus()
    guard status != .notDetermined, !pending.isEmpty else { return }
    let ssid = status == .authorizedAlways ? currentSSID() : nil
    let completions = pending
    pending.removeAll(keepingCapacity: true)
    for completion in completions {
      completion(ssid)
    }
  }

  private func currentSSID() -> String? {
    dispatchPrecondition(condition: .onQueue(.main))
    guard authorizationStatus() == .authorizedAlways else { return nil }
    let ssid = readSSID()
    return ssid?.isEmpty == false ? ssid : nil
  }

  private func onMain(_ operation: @escaping () -> Void) {
    if Thread.isMainThread {
      operation()
    } else {
      DispatchQueue.main.async(execute: operation)
    }
  }
}
