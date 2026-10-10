import AppKit
import Foundation
import SwiftUI

@main struct PerformanceChecks {
    @MainActor static func main() async throws {
        MarkdownChecks.run()
        try await RegressionChecks.run()
        try await EfficiencyChecks.run()
        print("PASS all performance regression checks")
    }
}
