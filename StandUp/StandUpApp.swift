import SwiftUI

@main
struct StandUpApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(appState: appState, postureTimer: appState.postureTimer)
                .environmentObject(appState)
        } label: {
            StatusBarLabelView(postureTimer: appState.postureTimer)
        }
        .menuBarExtraStyle(.window)
    }
}