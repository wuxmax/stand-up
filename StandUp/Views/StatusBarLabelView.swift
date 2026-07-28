import AppKit
import SwiftUI

/// Renders the tiny status string shown in the menu bar itself.
///
/// MenuBarExtra strips fonts/frames from label views (only images survive),
/// so the whole label is pre-rendered into a fixed-width NSImage: icon on the
/// left, monospaced-digit time right-aligned. Fixed canvas width keeps the
/// status item width constant as the countdown changes.
struct StatusBarLabelView: View {
    @ObservedObject var postureTimer: PostureTimer

    private let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private let iconSize = NSSize(width: 14, height: 14)
    private let gap: CGFloat = 2
    private let canvasHeight: CGFloat = 20

    var body: some View {
        Image(nsImage: makeLabelImage())
            .renderingMode(.template)
    }

    private func makeLabelImage() -> NSImage {
        let timeString = compactRemaining
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let textSize = (timeString as NSString).size(withAttributes: attrs)
        // Worst case is "60:00" (5 chars). Monospaced digits make any shorter
        // string strictly narrower, so this reference width is a stable box.
        let refWidth = ("00:00" as NSString).size(withAttributes: attrs).width
        let canvasWidth = iconSize.width + gap + refWidth

        let symbolName = postureTimer.posture.symbolName
        let image = NSImage(
            size: NSSize(width: canvasWidth, height: canvasHeight),
            flipped: false
        ) { _ in
            if let icon = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
                let iconRect = NSRect(
                    x: 0,
                    y: (canvasHeight - iconSize.height) / 2,
                    width: iconSize.width,
                    height: iconSize.height
                )
                icon.draw(in: iconRect)
            }
            let textRect = NSRect(
                x: canvasWidth - textSize.width,
                y: (canvasHeight - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            (timeString as NSString).draw(in: textRect, withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        return image
    }

    private var compactRemaining: String {
        let total = max(0, Int(postureTimer.remaining))
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}