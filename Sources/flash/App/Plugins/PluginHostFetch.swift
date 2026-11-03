import FlashCore
import Foundation

enum PluginHostFetch {
  struct Payload {
    let status: Int
    let data: Data
  }

  enum Failure: Error {
    case transport(Error)
    case oversized
    case disallowedURL
    case disallowedRedirect
    case invalidResponse

    var message: String {
      switch self {
      case .transport(let error): String(describing: error)
      case .oversized: "response exceeds the 1 MiB host.fetch cap"
      case .disallowedURL: "url not in fetch_urls allowlist"
      case .disallowedRedirect: "redirect not in fetch_urls allowlist"
      case .invalidResponse: "host.fetch requires an HTTP response"
      }
    }
  }

  @discardableResult
  static func start(
    request: URLRequest, allowlist: [String], configuration: URLSessionConfiguration,
    completion: @escaping (Result<Payload, Failure>) -> Void
  ) -> URLSessionDataTask {
    Transfer(allowlist: allowlist, completion: completion).start(
      request: request, configuration: configuration)
  }

  static func urlIsAllowed(_ text: String, byPrefix prefix: String) -> Bool {
    guard let url = canonicalURL(text), let allowed = canonicalURL(prefix), url.hasPrefix(allowed)
    else { return false }
    if url.count == allowed.count || allowed.hasSuffix("/") { return true }
    let next = url[url.index(url.startIndex, offsetBy: allowed.count)]
    return next == "/" || next == "?" || next == "#"
  }

  private static func canonicalURL(_ text: String) -> String? {
    guard var components = URLParsing.components(text),
      components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
      components.user == nil, components.password == nil,
      components.path.isEmpty || components.path.hasPrefix("/")
    else { return nil }
    components.scheme = "https"
    components.host = host.lowercased()
    if components.port == 443 { components.port = nil }
    // Decode before removing dot segments: encoded traversal must not turn
    // an approved /api prefix into a request for /private at the server.
    let parts = components.path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
    var path: [Substring] = []
    for part in parts {
      switch part {
      case ".": continue
      case "..": _ = path.popLast()
      default: path.append(part)
      }
    }
    components.path = "/" + path.joined(separator: "/")
    if let last = parts.last, last == "." || last == "..", !components.path.hasSuffix("/") {
      components.path += "/"
    }
    return components.url?.absoluteString
  }

  /// Mutable transfer state belongs only to this session's serial delegate
  /// queue. Session invalidation releases its delegate after the one result.
  private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let allowlist: [String]
    private var completion: ((Result<Payload, Failure>) -> Void)?
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var body = Data()

    init(allowlist: [String], completion: @escaping (Result<Payload, Failure>) -> Void) {
      self.allowlist = allowlist
      self.completion = completion
    }

    func start(request: URLRequest, configuration: URLSessionConfiguration) -> URLSessionDataTask {
      let delegateQueue = OperationQueue()
      delegateQueue.name = "flash.plugin.host_fetch"
      delegateQueue.maxConcurrentOperationCount = 1
      // A plugin's `perform` waits on this reply; the work itself is a copy.
      delegateQueue.qualityOfService = .userInitiated
      let isolated = configuration.copy() as! URLSessionConfiguration
      isolated.timeoutIntervalForResource = Double(PluginProtocol.fetchTimeoutMs) / 1_000
      isolated.httpCookieStorage = nil
      isolated.urlCredentialStorage = nil
      isolated.urlCache = nil
      let session = URLSession(
        configuration: isolated, delegate: self, delegateQueue: delegateQueue)
      self.session = session
      let task = session.dataTask(with: request)
      if isAllowed(request.url) {
        task.resume()
      } else {
        delegateQueue.addOperation { self.finish(.failure(.disallowedURL)) }
      }
      return task
    }

    private func isAllowed(_ url: URL?) -> Bool {
      guard let url else { return false }
      return allowlist.contains { PluginHostFetch.urlIsAllowed(url.absoluteString, byPrefix: $0) }
    }

    private func finish(_ result: Result<Payload, Failure>) {
      guard let completion else { return }
      self.completion = nil
      let session = self.session
      self.session = nil
      session?.invalidateAndCancel()
      body.removeAll()
      completion(result)
    }

    func urlSession(
      _ session: URLSession, task: URLSessionTask,
      willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
      completionHandler: @escaping (URLRequest?) -> Void
    ) {
      guard completion != nil else { return completionHandler(nil) }
      guard isAllowed(request.url) else {
        completionHandler(nil)
        finish(.failure(.disallowedRedirect))
        return
      }
      completionHandler(request)
    }

    func urlSession(
      _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
      completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
      guard completion != nil else { return completionHandler(.cancel) }
      guard let response = response as? HTTPURLResponse else {
        completionHandler(.cancel)
        finish(.failure(.invalidResponse))
        return
      }
      guard response.expectedContentLength <= Int64(PluginProtocol.maxFetchResponseBytes) else {
        completionHandler(.cancel)
        finish(.failure(.oversized))
        return
      }
      self.response = response
      completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      guard completion != nil else { return }
      guard data.count <= PluginProtocol.maxFetchResponseBytes - body.count else {
        finish(.failure(.oversized))
        return
      }
      body.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
      guard completion != nil else { return }
      if let error {
        finish(.failure(.transport(error)))
      } else if let response {
        finish(.success(Payload(status: response.statusCode, data: body)))
      } else {
        finish(.failure(.invalidResponse))
      }
    }
  }
}
