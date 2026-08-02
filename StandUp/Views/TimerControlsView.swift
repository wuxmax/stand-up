import SwiftUI

struct TimerControlsView: View {
    @ObservedObject var postureTimer: PostureTimer
    let onSwitchMode: () -> Void

    var body: some View {
        HStack {
            Button {
                toggleStartPause()
            } label: {
                Label(startPauseLabel, systemImage: startPauseSymbol)
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                postureTimer.reset()
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.bordered)

            Spacer()

            Button {
                onSwitchMode()
            } label: {
                Label("Switch", systemImage: "arrow.left.arrow.right")
            }
            .buttonStyle(.bordered)
        }
    }

    private var startPauseLabel: String {
        postureTimer.runState == .running ? "Pause" : "Start"
    }
    private var startPauseSymbol: String {
        postureTimer.runState == .running ? "pause.fill" : "play.fill"
    }

    private func toggleStartPause() {
        switch postureTimer.runState {
        case .running: postureTimer.pause()
        case .paused:  postureTimer.start()
        case .idle:    postureTimer.start()
        }
    }
}