//
//  NSViewController+SwiftUI.swift
//  TablePro
//
//  Helper extension to present SwiftUI views from AppKit
//

import AppKit
import SwiftUI

extension NSViewController {
    /// Present a SwiftUI view as a sheet with proper keyboard handling
    func presentAsSheet<Content: View>(_ swiftUIView: Content, onSave: (() -> Void)? = nil, onCancel: (() -> Void)? = nil) {
        let hostingController = KeyboardHandlingHostingController(rootView: swiftUIView)
        hostingController.onSave = onSave
        hostingController.onCancel = onCancel ?? { [weak hostingController] in
            hostingController?.dismiss(nil)
        }
        presentAsSheet(hostingController)
    }
}

/// Custom NSHostingController that properly handles keyboard events
private class KeyboardHandlingHostingController<Content: View>: NSHostingController<Content> {
    var onSave: (() -> Void)?
    var onCancel: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Check for Command modifier
        let commandPressed = event.modifierFlags.contains(.command)

        // Handle Cmd+Return (Save)
        if commandPressed && (event.keyCode == 36 || event.keyCode == 76) {
            onSave?()
            return true
        }

        // Let super handle other events
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        // Handle Escape key
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        // Check for Escape key without modifiers
        if event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty {
            onCancel?()
            return
        }

        // Pass other keys to super
        super.keyDown(with: event)
    }
}
