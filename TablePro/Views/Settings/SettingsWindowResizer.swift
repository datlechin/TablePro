//
//  SettingsWindowResizer.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Resizes the Settings window height to match the selected tab's preferred size.
/// Width stays fixed to keep all tab items visible. Uses AppKit's
/// `NSWindow.setFrame(_:display:animate:)` for smooth height transitions,
/// keeping the top-left corner pinned (standard macOS preferences behavior).
struct SettingsWindowResizer: NSViewRepresentable {
    var size: CGSize

    func makeNSView(context: Context) -> NSView {
        _SettingsWindowSizeView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        let newFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
        guard window.frame.size != newFrameSize else { return }
        var frame = window.frame
        frame.origin.y += frame.size.height - newFrameSize.height
        frame.size = newFrameSize
        window.setFrame(frame, display: true, animate: window.isVisible)
    }
}

private final class _SettingsWindowSizeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }
}
