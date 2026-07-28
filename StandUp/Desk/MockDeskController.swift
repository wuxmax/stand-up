import Foundation

/// Mock desk controller that simulates movement without any hardware.
/// Useful for iteration 1 and for testing the UI/flow without a real desk.
final class MockDeskController: DeskController {
    private(set) var snapshot: DeskSnapshot = .idle
    var eventHandler: ((DeskEvent) -> Void)?

    private var currentHeightMm: Int = 700
    private var moveTask: Task<Void, Never>?

    func connect() async {
        snapshot = DeskSnapshot(
            heightMm: currentHeightMm, speedMmPerSec: 0,
            target: nil, isMoving: false, connection: .connecting
        )
        notify(.snapshot(snapshot))
        notify(.log("Mock: connecting..."))
        try? await Task.sleep(nanoseconds: 300_000_000)
        snapshot = DeskSnapshot(
            heightMm: currentHeightMm, speedMmPerSec: 0,
            target: nil, isMoving: false, connection: .connected
        )
        notify(.snapshot(snapshot))
        notify(.log("Mock: connected (simulated desk)"))
    }

    func disconnect() {
        moveTask?.cancel()
        moveTask = nil
        snapshot = .idle
        notify(.snapshot(snapshot))
        notify(.log("Mock: disconnected"))
    }

    func moveTo(_ target: DeskTarget) async {
        moveTask?.cancel()
        let targetHeight = DeskSettings.default.targetHeightMm(for: target)
        snapshot = DeskSnapshot(
            heightMm: currentHeightMm, speedMmPerSec: 25,
            target: target, isMoving: true, connection: snapshot.connection
        )
        notify(.snapshot(snapshot))
        notify(.log("Mock: moving to \(targetHeight)mm"))

        let start = currentHeightMm
        let delta = targetHeight - start
        guard delta != 0 else {
            finishMove(at: targetHeight, target: target)
            return
        }
        let speedMmPerSec = 25
        let totalSeconds = max(1, abs(delta) / speedMmPerSec)
        moveTask = Task { [weak self] in
            guard let self else { return }
            for second in 1...totalSeconds {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                let progress = min(1, Double(second) / Double(totalSeconds))
                let h = start + Int(Double(delta) * progress)
                self.currentHeightMm = h
                self.snapshot = DeskSnapshot(
                    heightMm: h, speedMmPerSec: speedMmPerSec,
                    target: target, isMoving: true, connection: self.snapshot.connection
                )
                self.notify(.snapshot(self.snapshot))
            }
            self.finishMove(at: targetHeight, target: target)
        }
        await moveTask?.value
    }

    private func finishMove(at height: Int, target: DeskTarget) {
        currentHeightMm = height
        snapshot = DeskSnapshot(
            heightMm: height, speedMmPerSec: 0,
            target: target, isMoving: false, connection: snapshot.connection
        )
        notify(.snapshot(snapshot))
        notify(.log("Mock: reached \(height)mm"))
    }
}