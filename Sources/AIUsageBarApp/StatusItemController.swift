import AIUsageBarCore
import AppKit
import Combine
import SwiftUI

@MainActor
final class StatusItemController: NSObject {
    private let model: UsageModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private var trackingArea: NSTrackingArea?
    private var cancellable: AnyCancellable?

    init(model: UsageModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: 78)
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 370, height: 610)
        popover.contentViewController = NSHostingController(rootView: UsagePopoverView(model: model))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            button.toolTip = "AIUsageBar"
            button.setAccessibilityLabel("AI usage")

            let tracking = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            button.addTrackingArea(tracking)
            trackingArea = tracking
        }

        updateStatusImage()
        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusImage() }
        }

        if ProcessInfo.processInfo.environment["AIUSAGEBAR_SHOW_ON_LAUNCH"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                self?.showPopover()
            }
        }
    }

    @objc private func togglePopover() {
        popover.isShown ? popover.performClose(nil) : showPopover()
    }

    @objc func mouseEntered(with event: NSEvent) {
        showPopover()
    }

    private func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func updateStatusImage() {
        let provider = model.primaryProvider
        let state = model.state(for: provider)
        statusItem.button?.image = MeterImageRenderer.image(
            provider: provider,
            usedPercent: state.snapshot?.weekly.usedPercent,
            isStale: state.failure != nil
        )
        statusItem.button?.setAccessibilityLabel(
            "\(provider.displayName) \(state.snapshot.map { "\(Int($0.weekly.usedPercent.rounded())) percent used" } ?? "unavailable")"
        )
    }
}

private enum MeterImageRenderer {
    static func image(provider: ProviderID, usedPercent: Double?, isStale: Bool) -> NSImage {
        let size = NSSize(width: 72, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            let alpha: CGFloat = isStale ? 0.55 : 1
            let labelColor = NSColor.labelColor.withAlphaComponent(alpha)
            let trackColor = NSColor.secondaryLabelColor.withAlphaComponent(0.22)
            let fillColor = provider.appKitAccent.withAlphaComponent(alpha)

            let initial = provider.menuInitial
            let initialAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: labelColor,
            ]
            initial.draw(at: NSPoint(x: 0, y: 4), withAttributes: initialAttributes)

            let track = NSBezierPath(roundedRect: NSRect(x: 13, y: 7, width: 28, height: 6), xRadius: 3, yRadius: 3)
            trackColor.setFill()
            track.fill()

            if let usedPercent {
                let width = 28 * min(max(usedPercent, 0), 100) / 100
                if width > 0 {
                    let fill = NSBezierPath(roundedRect: NSRect(x: 13, y: 7, width: width, height: 6), xRadius: 3, yRadius: 3)
                    fillColor.setFill()
                    fill.fill()
                }
            }

            let percentage = usedPercent.map { "\(Int($0.rounded()))%" } ?? "--"
            let percentageAttributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: labelColor,
            ]
            percentage.draw(at: NSPoint(x: 44, y: 4), withAttributes: percentageAttributes)
            return true
        }
        image.isTemplate = false
        return image
    }
}
