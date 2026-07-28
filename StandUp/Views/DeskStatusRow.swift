import SwiftUI

struct DeskStatusRow: View {
    let snapshot: DeskSnapshot

    var body: some View {
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
            if let h = snapshot.heightMm {
                Text("\(h) mm")
                    .font(.system(.caption, design: .monospaced))
            }
            if snapshot.isMoving {
                Image(systemName: "arrow.up.arrow.down")
                    .foregroundStyle(.tint)
            }
        }
    }

    private var connectionSymbol: String {
        switch snapshot.connection {
        case .connected:     return "macwindow.fill"
        case .connecting:    return "macwindow"
        case .disconnected:  return "macwindow"
        case .error:         return "exclamationmark.triangle"
        }
    }

    private var connectionColor: Color {
        switch snapshot.connection {
        case .connected:     return .green
        case .connecting:    return .orange
        case .disconnected:  return .secondary
        case .error:         return .red
        }
    }

    private var connectionText: String {
        switch snapshot.connection {
        case .connected:     return "Connected"
        case .connecting:    return "Connecting..."
        case .disconnected:  return "Disconnected"
        case .error(let m):  return m
        }
    }
}