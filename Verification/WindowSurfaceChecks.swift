import AppKit
import Foundation
import SwiftUI

/// Window-level transparency runs through `WindowTransparencyBridge`, which
/// defers its work to the main queue. These checks drive the policy it uses
/// (`TransparencyAnchor.configure`) against a throwaway window, so the two
/// behaviours the bridge promises are held down without depending on queue
/// timing: a window that follows the preference becomes clear-backed above 0%,
/// and the Settings window, which passes `keepsOwnSurface`, never does. Settings
/// losing that surface is what let a click land on the chat window underneath.
@MainActor
func runWindowSurfaceChecks() {
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.prohibited)

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
        styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
    func configure(_ transparency: Double, _ reduceTransparency: Bool, _ keepsOwnSurface: Bool) {
        WindowTransparencyBridge.TransparencyAnchor.configure(
            window,
            transparency: transparency,
            reduceTransparency: reduceTransparency,
            keepsOwnSurface: keepsOwnSurface
        )
    }

    // Settings keeps its own opaque surface at every level, so it always reads
    // as its own window and takes the clicks and scrolls that land on it.
    configure(0.8, false, true)
    precondition(window.isOpaque, "Settings lost its opaque backing at 80% transparency")
    precondition(window.backgroundColor == .windowBackgroundColor,
                 "Settings backing colour is not the window background")

    configure(0, false, true)
    precondition(window.isOpaque, "Settings became transparent at 0%")

    // Every other window clears its backing above 0%, so the desktop shows through.
    configure(0.8, false, false)
    precondition(!window.isOpaque, "Chat window stayed opaque at 80% transparency")
    precondition(window.backgroundColor == .clear, "Chat window backing was not cleared")

    // Reduce Transparency overrides the preference.
    configure(0.8, true, false)
    precondition(window.isOpaque, "Reduce Transparency did not restore an opaque window")
    precondition(window.backgroundColor == .windowBackgroundColor,
                 "Reduce Transparency left a clear backing")

    // And 0% restores the opaque window.
    configure(0, false, false)
    precondition(window.isOpaque, "Window stayed transparent at 0%")

    window.close()
    print("Window transparency surface checks passed")
}
