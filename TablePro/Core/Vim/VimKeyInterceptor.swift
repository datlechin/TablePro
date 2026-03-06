//
//  VimKeyInterceptor.swift
//  TablePro
//
//  Intercepts key events for Vim mode via NSEvent local monitor
//

import AppKit
import CodeEditSourceEditor

/// Intercepts keyboard events and routes them through the Vim engine
@MainActor
final class VimKeyInterceptor {
    private let engine: VimEngine
    private weak var inlineSuggestionManager: InlineSuggestionManager?
    nonisolated(unsafe) private var monitor: Any?
    private weak var controller: TextViewController?
    nonisolated(unsafe) private var popupCloseObserver: NSObjectProtocol?

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let popupCloseObserver { NotificationCenter.default.removeObserver(popupCloseObserver) }
    }

    init(engine: VimEngine, inlineSuggestionManager: InlineSuggestionManager?) {
        self.engine = engine
        self.inlineSuggestionManager = inlineSuggestionManager
    }

    /// Install the key event monitor
    func install(controller: TextViewController) {
        self.controller = controller
        uninstall()

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyEvent(event)
        }

        // Observe autocomplete popup close. When SuggestionController's popup
        // consumes Escape (closes itself), we also need to exit Insert/Visual mode.
        // queue: .main → handler runs synchronously when posted from main thread,
        // so NSApp.currentEvent is still the Escape keyDown event.
        popupCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let closingWindow = notification.object as? NSWindow,
                  closingWindow.windowController is SuggestionController,
                  let editorWindow = self.controller?.textView.window,
                  editorWindow.childWindows?.contains(closingWindow) == true,
                  let currentEvent = NSApp.currentEvent,
                  currentEvent.type == .keyDown,
                  currentEvent.keyCode == 53,
                  self.engine.mode != .normal else {
                return
            }
            self.inlineSuggestionManager?.dismissSuggestion()
            _ = self.engine.process("\u{1B}", shift: false)
        }
    }

    /// Remove the key event monitor
    func uninstall() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
        monitor = nil
        if let popupCloseObserver {
            NotificationCenter.default.removeObserver(popupCloseObserver)
        }
        popupCloseObserver = nil
    }

    /// Arrow key Unicode scalars → Vim motion characters
    private static let arrowToVimKey: [UInt32: Character] = [
        0xF700: "k", // Up
        0xF701: "j", // Down
        0xF702: "h", // Left
        0xF703: "l"  // Right
    ]

    // MARK: - Event Handling

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Only intercept when our text view is first responder
        guard let textView = controller?.textView,
              event.window === textView.window,
              textView.window?.firstResponder === textView else {
            return event
        }

        // Pass through all events with Cmd or Option modifiers
        // (system shortcuts like Cmd+C, Cmd+V, Cmd+Z, etc.)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command) || modifiers.contains(.option) {
            return event
        }

        // Ctrl+R in Normal mode → redo (Vim convention)
        if modifiers.contains(.control) {
            if !engine.mode.isInsert && event.keyCode == 15 { // keyCode 15 = R
                engine.redo()
                return nil
            }
            return event // Pass through other Ctrl combinations
        }

        // Translate NSEvent to Character
        guard let characters = event.characters, let char = characters.first else {
            return event
        }

        // In non-insert modes, translate arrow keys to h/j/k/l so the Vim engine
        // handles them (critical for visual mode selection to work with arrows).
        if let scalar = char.unicodeScalars.first, scalar.value >= 0xF700 {
            if !engine.mode.isInsert, let vimChar = Self.arrowToVimKey[scalar.value] {
                let consumed = engine.process(vimChar, shift: modifiers.contains(.shift))
                return consumed ? nil : event
            }
            return event // Pass through non-arrow function keys and insert-mode arrows
        }

        // In non-normal modes, Escape should exit to Normal mode.
        // Also dismiss any active inline suggestion and close autocomplete popup.
        if engine.mode != .normal && char == "\u{1B}" {
            inlineSuggestionManager?.dismissSuggestion()
            closeSuggestionPopup()
        }

        // Feed to Vim engine
        let shift = modifiers.contains(.shift)
        let consumed = engine.process(char, shift: shift)

        return consumed ? nil : event
    }

    private func closeSuggestionPopup() {
        guard let window = controller?.textView.window else { return }
        for childWindow in window.childWindows ?? [] {
            if childWindow.windowController is SuggestionController {
                childWindow.windowController?.close()
            }
        }
    }
}
