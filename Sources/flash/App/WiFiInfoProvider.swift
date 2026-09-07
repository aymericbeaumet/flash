import CoreLocation
import CoreWLAN
import Foundation

protocol WiFiInfoProviding: AnyObject {
  func fetchSSID(
    requestAuthorization: Bool,
    completion: @escaping (String?) -> Void
  )
}

/// Owns the host's Location authorization request for the narrow purpose of
/// reading the current Wi-Fi SSID. CoreLocation never receives location
/// updates; it is used only for the permission CoreWLAN requires.
final class WiFiInfoProvider: WiFiInfoProviding {
  private let locationManager: CLLocationManager?
  private let authorizationStatus: () -> CLAuthorizationStatus
  private let requestAuthorization: () -> Void
  private let readSSID: () -> String?

  init() {
    let manager = CLLocationManager()
    locationManager = manager
    authorizationStatus = { manager.authorizationStatus }
    requestAuthorization = { manager.requestWhenInUseAuthorization() }
    readSSID = {
      CWWiFiClient.shared().interface(withName: nil)?.ssid()
    }
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
  }

  func fetchSSID(
    requestAuthorization shouldRequestAuthorization: Bool,
    completion: @escaping (String?) -> Void
  ) {
    onMain { [self] in
      resolveOrRequest(
        shouldRequestAuthorization: shouldRequestAuthorization,
        completion)
    }
  }

  private func resolveOrRequest(
    shouldRequestAuthorization: Bool,
    _ completion: @escaping (String?) -> Void
  ) {
    dispatchPrecondition(condition: .onQueue(.main))
    switch authorizationStatus() {
    case .authorizedAlways:
      completion(currentSSID())
    case .notDetermined:
      if shouldRequestAuthorization {
        requestAuthorization()
      }
      // Never retain a plugin reply behind an open-ended system prompt. The
      // user can retry explicitly after granting access; passive polls will
      // also pick up the now-authorized SSID.
      completion(nil)
    case .denied, .restricted:
      completion(nil)
    @unknown default:
      completion(nil)
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
