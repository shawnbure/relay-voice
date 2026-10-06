import SwiftUI
import UserNotifications
import UIKit

@MainActor
final class RelayNotifications: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var session: RelaySession?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
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
        let peer = notification.request.content.userInfo["peer"] as? String
        let viewing = peer != nil && Self.session?.isViewing(peer!) == true
        let muted = peer != nil && Self.session?.isMuted(peer!) == true
        Task { await Self.session?.refresh(); Self.session?.notificationArrived() }
        completionHandler(viewing || muted ? [.badge] : [.banner, .sound, .badge])
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        Self.session?.notificationPeer = response.notification.request.content.userInfo["peer"] as? String
        Task { await Self.session?.resume() }
        completionHandler()
    }
}

@main
struct RelayApp: App {
    @UIApplicationDelegateAdaptor(RelayNotifications.self) private var notifications
    @StateObject private var session = RelaySession()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup { RootView().environmentObject(session).environmentObject(session.voice).task { RelayNotifications.session = session; await session.restore() } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await session.resume() } } }
    }
}
