import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var postureTimer: PostureTimer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerRow

            Divider()
            TimerControlsView(postureTimer: postureTimer) {
                appState.switchModeNow()
            }

            if appState.isDeskControlEnabled {
                Divider()
                DeskStatusRow(snapshot: appState.deskSnapshot)
                Button("Move desk to \(postureTimer.posture.opposite.label)") {
                    Task { await appState.moveDeskToCurrentPosture() }
                }
                .disabled(appState.deskSnapshot.connection != .connected)
            }

            if !appState.notificationsAuthorized {
                Divider()
                HStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Notifications are off")
                            .font(.caption.weight(.medium))
                        Text("Open System Settings to enable sit/stand reminders.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open") {
                        appState.openSystemNotificationSettings()
                    }
                    .buttonStyle(.bordered)
                }
            }

            Divider()
            Button("Settings...") {
                SettingsWindowController.shared.open(appState: appState)
            }
            .buttonStyle(.borderless)

            Button("Quit StandUp") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(minWidth: 300)
        .onAppear { appState.onAppear() }
        .onDisappear { appState.onDisappear() }
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: postureTimer.posture.symbolName)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
            Text(postureTimer.posture.label)
                .font(.headline)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(formatRemaining(postureTimer.remaining))
                .font(.system(.title, design: .monospaced).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}