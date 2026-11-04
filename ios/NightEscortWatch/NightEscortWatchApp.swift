import SwiftUI

@main
struct NightEscortWatchApp: App {
    @StateObject private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView().environmentObject(model)
        }
    }
}
