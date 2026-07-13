import AppKit
import SwiftUI

@main
enum AIUsageBarMain {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        let isUITest = ProcessInfo.processInfo.environment["AIUSAGEBAR_UI_TEST"] == "1"
        application.setActivationPolicy(isUITest ? .regular : .accessory)
        application.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?
    private var testWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = UsageModel()
        statusController = StatusItemController(model: model)
        model.refresh()
        model.startAutomaticRefresh()

        if ProcessInfo.processInfo.environment["AIUSAGEBAR_UI_TEST"] == "1" {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 370, height: 520),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "AIUsageBar UI Test"
            window.contentViewController = NSHostingController(rootView: UsagePopoverView(model: model))
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            testWindow = window
        }
    }
}
