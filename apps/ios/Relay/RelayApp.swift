import SwiftUI

@main
struct RelayApp: App {
    @StateObject private var session = RelaySession()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup { RootView().environmentObject(session).environmentObject(session.voice).task { await session.restore() } }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await session.resume() } } }
    }
}
