import AIUsageBarCore
import AppKit
import SwiftUI

extension ProviderID {
    var menuInitial: String {
        switch self {
        case .codex: "C"
        case .claude: "A"
        }
    }

    var appKitAccent: NSColor {
        switch self {
        case .codex: .systemGreen
        case .claude: .systemOrange
        }
    }

    var swiftUIAccent: Color {
        Color(nsColor: appKitAccent)
    }
}
