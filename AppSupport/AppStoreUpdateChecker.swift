import Foundation
import SwiftUI

@MainActor
final class AppStoreUpdateChecker: ObservableObject {
  struct AvailableUpdate: Equatable {
    let version: String
    let storeURL: URL
  }

  private enum DefaultsKey {
    static let checksEnabled = "appStoreUpdateChecksEnabled"
    static let ignoredVersion = "appStoreIgnoredUpdateVersion"
    static let remindAfter = "appStoreUpdateRemindAfter"
    static let lastCheck = "appStoreUpdateLastCheck"
    static let cachedVersion = "appStoreUpdateCachedVersion"
    static let cachedStoreURL = "appStoreUpdateCachedStoreURL"
  }

  private struct LookupResponse: Decodable {
    let results: [LookupResult]
  }

  private struct LookupResult: Decodable {
    let version: String
    let trackViewUrl: String?
  }

  private static let appStoreID = "6751489740"
  private static let checkInterval: TimeInterval = 24 * 60 * 60
  private static let reminderInterval: TimeInterval = 24 * 60 * 60
  private static let periodicWakeInterval: UInt64 = 60 * 60 * 1_000_000_000

  private let defaults: UserDefaults
  private let session: URLSession
  private let bundle: Bundle
  private var isChecking = false

  @Published private(set) var availableUpdate: AvailableUpdate?
  @Published var checksEnabled: Bool {
    didSet {
      guard checksEnabled != oldValue else { return }
      defaults.set(checksEnabled, forKey: DefaultsKey.checksEnabled)
      if checksEnabled {
        defaults.removeObject(forKey: DefaultsKey.remindAfter)
        Task { await checkForUpdates(force: true) }
      } else {
        availableUpdate = nil
      }
    }
  }

  init(
    defaults: UserDefaults = .standard,
    session: URLSession = .shared,
    bundle: Bundle = .main
  ) {
    self.defaults = defaults
    self.session = session
    self.bundle = bundle
    if defaults.object(forKey: DefaultsKey.checksEnabled) == nil {
      self.checksEnabled = true
    } else {
      self.checksEnabled = defaults.bool(forKey: DefaultsKey.checksEnabled)
    }
  }

  func runPeriodicChecks() async {
    while !Task.isCancelled {
      await checkForUpdates()
      do {
        try await Task.sleep(nanoseconds: Self.periodicWakeInterval)
      } catch {
        return
      }
    }
  }

  func checkForUpdates(force: Bool = false) async {
    guard checksEnabled else { return }
    presentCachedUpdateIfEligible()

    if !force,
       let lastCheck = defaults.object(forKey: DefaultsKey.lastCheck) as? Date,
       Date().timeIntervalSince(lastCheck) < Self.checkInterval {
      return
    }
    guard !isChecking else { return }
    isChecking = true
    defer { isChecking = false }
    defaults.set(Date(), forKey: DefaultsKey.lastCheck)

    do {
      let request = try makeLookupRequest()
      let (data, response) = try await session.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse,
            (200...299).contains(httpResponse.statusCode) else {
        return
      }
      let lookup = try JSONDecoder().decode(LookupResponse.self, from: data)
      guard let result = lookup.results.first else { return }

      defaults.set(result.version, forKey: DefaultsKey.cachedVersion)
      let storeURL = result.trackViewUrl.flatMap(URL.init(string:)) ?? fallbackStoreURL
      defaults.set(storeURL.absoluteString, forKey: DefaultsKey.cachedStoreURL)
      presentUpdateIfEligible(version: result.version, storeURL: storeURL)
    } catch {
      // Update checks are optional and must never interfere with app startup.
    }
  }

  func remindLater() {
    defaults.set(
      Date().addingTimeInterval(Self.reminderInterval),
      forKey: DefaultsKey.remindAfter
    )
    availableUpdate = nil
  }

  func ignoreCurrentUpdate() {
    guard let availableUpdate else { return }
    defaults.set(availableUpdate.version, forKey: DefaultsKey.ignoredVersion)
    defaults.removeObject(forKey: DefaultsKey.remindAfter)
    self.availableUpdate = nil
  }

  func neverRemindAgain() {
    checksEnabled = false
  }

  func appStoreURLForCurrentUpdate() -> URL? {
    guard let availableUpdate else { return nil }
    remindLater()
    return availableUpdate.storeURL
  }

  private var currentVersion: String {
    bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
  }

  private var fallbackStoreURL: URL {
    URL(string: "https://apps.apple.com/app/id\(Self.appStoreID)")!
  }

  private func makeLookupRequest() throws -> URLRequest {
    var components = URLComponents(string: "https://itunes.apple.com/lookup")!
    var queryItems = [URLQueryItem(name: "id", value: Self.appStoreID)]
    if let region = Locale.current.region?.identifier {
      queryItems.append(URLQueryItem(name: "country", value: region))
    }
    components.queryItems = queryItems
    guard let url = components.url else { throw URLError(.badURL) }
    var request = URLRequest(
      url: url,
      cachePolicy: .reloadIgnoringLocalCacheData,
      timeoutInterval: 15
    )
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  private func presentCachedUpdateIfEligible() {
    guard let version = defaults.string(forKey: DefaultsKey.cachedVersion) else { return }
    let storeURL = defaults.string(forKey: DefaultsKey.cachedStoreURL)
      .flatMap(URL.init(string:)) ?? fallbackStoreURL
    presentUpdateIfEligible(version: version, storeURL: storeURL)
  }

  private func presentUpdateIfEligible(version: String, storeURL: URL) {
    guard version.compare(currentVersion, options: .numeric) == .orderedDescending,
          defaults.string(forKey: DefaultsKey.ignoredVersion) != version else {
      if availableUpdate?.version == version {
        availableUpdate = nil
      }
      return
    }
    if let remindAfter = defaults.object(forKey: DefaultsKey.remindAfter) as? Date,
       remindAfter > Date() {
      return
    }
    availableUpdate = AvailableUpdate(version: version, storeURL: storeURL)
  }
}

private struct AppStoreUpdateAlertModifier: ViewModifier {
  @Environment(\.openURL) private var openURL
  @Environment(\.scenePhase) private var scenePhase
  @ObservedObject var updateChecker: AppStoreUpdateChecker

  func body(content: Content) -> some View {
    content
      .task {
        await updateChecker.runPeriodicChecks()
      }
      .onChange(of: scenePhase) { _, phase in
        guard phase == .active else { return }
        Task { await updateChecker.checkForUpdates() }
      }
      .alert(
        "Update Available",
        isPresented: updateAlertIsPresented
      ) {
        Button("View in App Store") {
          if let url = updateChecker.appStoreURLForCurrentUpdate() {
            openURL(url)
          }
        }
        Button("Remind Me Later", role: .cancel) {
          updateChecker.remindLater()
        }
        Button("Ignore This Update") {
          updateChecker.ignoreCurrentUpdate()
        }
        Button("Never Remind Me") {
          updateChecker.neverRemindAgain()
        }
      } message: {
        if let update = updateChecker.availableUpdate {
          Text(
            String(
              format: String(localized: "A newer version of BorgVR (%@) is available in the App Store. You are currently using version %@."),
              update.version,
              currentVersion
            )
          )
        }
      }
  }

  private var updateAlertIsPresented: Binding<Bool> {
    Binding(
      get: { updateChecker.availableUpdate != nil },
      set: { isPresented in
        if !isPresented, updateChecker.availableUpdate != nil {
          updateChecker.remindLater()
        }
      }
    )
  }

  private var currentVersion: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
  }
}

extension View {
  func appStoreUpdateAlert(using updateChecker: AppStoreUpdateChecker) -> some View {
    modifier(AppStoreUpdateAlertModifier(updateChecker: updateChecker))
  }
}
