import SwiftUI
import UserNotifications
import UIKit

@MainActor
final class RelayNotifications: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var session: RelaySession?
    static let copyCodeAction = "COPY_CODE"
    /// True while a Relay window is in front and focused. A Mac app keeps running behind other windows,
    /// so "the app is running" is not the same as "the person can see it".
    private var isFrontmost: Bool { UIApplication.shared.connectedScenes.contains { $0.activationState == .foregroundActive } }
    /// On Mac, keeps macOS from napping Relay in the background so the calling connection stays live and calls ring.
    private var macActivity: NSObjectProtocol?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Sign-in texts carry a "Copy Code" button (the server sets this category when it finds a code).
        let copy = UNNotificationAction(identifier: Self.copyCodeAction, title: "Copy Code", options: [])
        UNUserNotificationCenter.current().setNotificationCategories([UNNotificationCategory(identifier: "VERIFICATION_CODE", actions: [copy], intentIdentifiers: [], options: [])])
        if ProcessInfo.processInfo.isMacCatalystApp {
            macActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Relay listens for incoming calls")
        }
        return true
    }
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Keychain.save(deviceToken.map { String(format: "%02x", $0) }.joined(), key: "relay.apns.token")
        Task { await Self.session?.registerPushDevice() }
    }
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs registration failed: \(error.localizedDescription)")
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // A ringing call already shows CallKit (iPhone) or the in-app call screen; skip the alert only when that screen is visible.
        if notification.request.content.userInfo["kind"] as? String == "incoming_call", Self.session?.voice.isInCall == true, VoiceManager.usesCallKit || isFrontmost { completionHandler([]); return }
        let peer = notification.request.content.userInfo["peer"] as? String
        // Only skip the banner for the open conversation when it is actually in view.
        let viewing = peer != nil && Self.session?.isViewing(peer!) == true && isFrontmost
        let muted = peer != nil && Self.session?.isMuted(peer!) == true
        Task { await Self.session?.refresh(); Self.session?.notificationArrived() }
        completionHandler(viewing || muted ? [.badge] : [.banner, .sound, .badge])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let code = info["code"] as? String {
            UIPasteboard.general.string = code
            if response.actionIdentifier == Self.copyCodeAction { completionHandler(); return }
        }
        let peer = info["peer"] as? String, line = info["line"] as? String
        Task {
            // Open the thread on the line it arrived on.
            if let line, Self.session?.showingAllLines != true { await Self.session?.selectLine(line) }
            Self.session?.notificationPeer = peer
            await Self.session?.resume()
        }
        completionHandler()
    }
}

@main
struct RelayApp: App {
    @UIApplicationDelegateAdaptor(RelayNotifications.self) private var notifications
    @StateObject private var session = RelaySession()
    @StateObject private var lock = AppLock()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup { RootView().environmentObject(session).environmentObject(session.voice).environmentObject(lock).task { RelayNotifications.session = session; await session.restore() } }
            .onChange(of: scenePhase) { _, phase in
                switch phase {
                case .active: Task { await lock.didBecomeActive(); await session.resume() }
                case .background: lock.didEnterBackground()
                default: break
                }
            }
    }
}
