import AppKit
import SwiftUI

struct DeskControlView: View {
    @ObservedObject var appState: AppState
    @State private var keyMonitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusRow

            if appState.deskSnapshot.connection == .connected {
                HStack(alignment: .center, spacing: 16) {
                    jogColumn
                    VStack(spacing: 8) {
                        presetCard(label: "Stand", heightMm: appState.deskSettings.standHeightMm) {
                            Task { await appState.moveDesk(to: .stand) }
                        } onSet: {
                            appState.setStandPresetToCurrentHeight()
                        }
                        presetCard(label: "Sit", heightMm: appState.deskSettings.sitHeightMm) {
                            Task { await appState.moveDesk(to: .sit) }
                        } onSet: {
                            appState.setSitPresetToCurrentHeight()
                        }
                    }
                }
            }
        }
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: connectionSymbol)
                .foregroundStyle(connectionColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Desk")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(connectionText)
                    .font(.caption.weight(.medium))
            }
            Spacer()
            if let target = appState.deskSnapshot.target,
               let height = appState.deskSnapshot.heightMm {
                let targetMm = appState.deskSettings.targetHeightMm(for: target)
                let direction = targetMm >= height ? "arrow.up" : "arrow.down"
                HStack(spacing: 2) {
                    Image(systemName: direction)
                        .font(.caption.weight(.semibold))
                    Text("\(targetMm)")
                        .font(.system(.caption, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                }
                .foregroundStyle(.tint)
            }
        }
    }

    private var jogColumn: some View {
        VStack(spacing: 6) {
            JogButton(systemName: "arrow.up") {
                appState.jogDeskUp()
            } onRelease: {
                appState.stopDesk()
            }

            VStack(spacing: 0) {
                if let h = appState.deskSnapshot.heightMm {
                    Text("\(h)")
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .monospacedDigit()
                } else {
                    Text("--")
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .foregroundStyle(Color.secondary)
                }
                Text("mm")
                    .font(.caption2)
                    .foregroundStyle(Color.secondary)
            }

            JogButton(systemName: "arrow.down") {
                appState.jogDeskDown()
            } onRelease: {
                appState.stopDesk()
            }
        }
        .frame(width: 80)
    }

    private func presetCard(label: String, heightMm: Int, onMove: @escaping () -> Void, onSet: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: onMove) {
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(Color.secondary)
                        Text("\(heightMm) mm")
                            .font(.subheadline.weight(.medium))
                            .monospacedDigit()
                    }
                    Spacer()
                    Image(systemName: "arrow.right.circle")
                        .foregroundStyle(Color.secondary)
                        .font(.caption)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: onSet) {
                Label("Set current", systemImage: "ruler")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.15)))
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [appState] event in
            guard appState.deskSnapshot.connection == .connected else { return event }
            switch event.keyCode {
            case 126:
                if event.type == .keyDown {
                    if !event.isARepeat { appState.jogDeskUp() }
                } else if event.type == .keyUp {
                    appState.stopDesk()
                }
                return nil
            case 125:
                if event.type == .keyDown {
                    if !event.isARepeat { appState.jogDeskDown() }
                } else if event.type == .keyUp {
                    appState.stopDesk()
                }
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    private var connectionSymbol: String {
        switch appState.deskSnapshot.connection {
        case .connected:     return "checkmark.circle.fill"
        case .connecting:    return "arrow.triangle.2.circlepath"
        case .scanning:      return "antenna.radiowaves.left.and.right"
        case .disconnected:  return "circle"
        case .error:         return "exclamationmark.triangle"
        }
    }

    private var connectionColor: Color {
        switch appState.deskSnapshot.connection {
        case .connected:     return .green
        case .connecting:    return .orange
        case .scanning:      return .orange
        case .disconnected:  return .secondary
        case .error:         return .red
        }
    }

    private var connectionText: String {
        switch appState.deskSnapshot.connection {
        case .connected:     return "Connected"
        case .connecting:    return "Connecting..."
        case .scanning:      return "Scanning..."
        case .disconnected:  return "Disconnected"
        case .error(let m):  return m
        }
    }
}

private struct JogButton: View {
    let systemName: String
    let onStart: () -> Void
    let onRelease: () -> Void
    @State private var isPressed = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 22, weight: .heavy))
            .frame(width: 56, height: 40)
            .foregroundStyle(isPressed ? Color.accentColor : Color.primary)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isPressed ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.15))
            )
            .scaleEffect(isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            onStart()
                        }
                    }
                    .onEnded { _ in
                        isPressed = false
                        onRelease()
                    }
            )
    }
}