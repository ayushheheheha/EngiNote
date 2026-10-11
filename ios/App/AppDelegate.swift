import UIKit

// EngiNote for iPad: one window holding one web view (NoteViewController) that shows the web app
// bundled with the app. Everything the user sees is the web app; this shell only adds what a web
// page cannot have.

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: "Default", sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: windowScene)
        let notes = NoteViewController()
        window.rootViewController = notes
        window.makeKeyAndVisible()
        self.window = window
        // Opened by sharing a file to EngiNote while the app was not running.
        let urls = connectionOptions.urlContexts.map { $0.url }
        if !urls.isEmpty { notes.receive(urls) }
    }

    // Opened by sharing a file to EngiNote while the app was running.
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        (window?.rootViewController as? NoteViewController)?.receive(contexts.map { $0.url })
    }
}
