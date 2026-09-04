import UIKit

/// Append-only launch breadcrumb. If the app dies between the launch screen
/// and first draw, this file (in Caches) records the last completed stage.
/// It uses only Foundation file writes so it works even when os_log capture
/// misses a fast abort.
func DTLaunchBreadcrumb(_ stage: String) {
    let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
        .appendingPathComponent("DraftingTable-launch-stages.log", isDirectory: false)
    guard let url else { return }
    let entry = "\(Date().timeIntervalSince1970) \(stage)\n"
    if FileManager.default.fileExists(atPath: url.path),
       let handle = try? FileHandle(forWritingTo: url) {
        defer { _ = try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(entry.utf8))
    } else {
        try? entry.write(to: url, atomically: true, encoding: .utf8)
    }
}

@main
final class DraftingTableApp: UIResponder, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        DTLaunchBreadcrumb("didFinishLaunching")
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
}

final class DraftingTableSceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        DTLaunchBreadcrumb("willConnectTo:start")
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        DTLaunchBreadcrumb("willConnectTo:windowCreated")
        window.rootViewController = UINavigationController(rootViewController: DraftingTableViewController())
        DTLaunchBreadcrumb("willConnectTo:rootInstalled")
        window.overrideUserInterfaceStyle = .light
        self.window = window
        window.makeKeyAndVisible()
        DTLaunchBreadcrumb("willConnectTo:visible")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
        guard let navigation = window?.rootViewController as? UINavigationController,
              let canvasController = navigation.viewControllers.first as? DraftingTableViewController else { return }
        canvasController.saveDocument()
    }

    /// Files/iCloud providers deliver `.drafttable` package URLs here when the
    /// app is opened externally.  The view controller validates and installs
    /// the candidate package transactionally.
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        guard let url = URLContexts.first?.url,
              let navigation = window?.rootViewController as? UINavigationController,
              let controller = navigation.viewControllers.first as? DraftingTableViewController else { return }
        controller.openPackage(at: url)
    }
}
