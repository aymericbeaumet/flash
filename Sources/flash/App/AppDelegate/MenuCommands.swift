import AppKit

/// `menu choose`: the command line shows the file's lines as the whole
/// flashlight pool until Return picks one or a close cancels; see
/// `MenuChoice` and the finder's `menu`.
extension AppDelegate {
  func performMenuChoose(
    file: String, prompt: String? = nil,
    completion: @escaping (Result<String, MenuChoiceError>) -> Void
  ) {
    // The file is read off main: it may be large, and main stays free.
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let loaded = MenuChoice.load(path: file)
      DispatchQueue.main.async {
        guard let self else { return completion(.failure(.cancelled)) }
        switch loaded {
        case .failure(let failure):
          FlashLog.info("[menu] choose_failed", fields: ["reason": failure.description])
          completion(.failure(failure))
        case .success(let items):
          FlashLog.debug("[menu] choose_open", fields: ["items": String(items.count)])
          let session = MenuSession(candidates: MenuChoice.candidates(items), prompt: prompt) {
            result in
            if case .success = result { FlashLog.debug("[menu] choose_picked") }
            completion(result)
          }
          // No catalog session: the pick's rows are the pool.
          self.enterCommandLineMode(initialText: "flashlight ", menu: session)
        }
      }
    }
  }
}
