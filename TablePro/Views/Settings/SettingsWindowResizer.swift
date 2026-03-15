//
//  SettingsWindowResizer.swift
//  TablePro
//

import AppKit
import SwiftUI

/// Resizes the Settings window to match the selected tab's preferred size.
/// Uses AppKit's `NSWindow.setFrame(_:display:animate:)` for smooth transitions,
/// keeping the top-left corner pinned (standard macOS preferences behavior).
struct SettingsWindowResizer: NSViewRepresentable {
    var size: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = _SettingsWindowSizeView()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        let contentSize = size
        let newFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize)).size
        var frame = window.frame
        // Pin top-left corner
        frame.origin.y += frame.size.height - newFrameSize.height
        frame.size = newFrameSize
        let shouldAnimate = window.isVisible
        window.setFrame(frame, display: true, animate: shouldAnimate)
        window.minSize = newFrameSize
        window.maxSize = newFrameSize
    }
}

private final class _SettingsWindowSizeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }
}
