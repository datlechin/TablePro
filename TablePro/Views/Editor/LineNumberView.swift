//
//  LineNumberView.swift
//  TablePro
//
//  Custom line number view without NSRulerView to prevent text blurring
//  Production-ready implementation for macOS SQL editor
//

import AppKit

/// Custom line number view positioned left of NSScrollView
/// Uses non-layer-backed drawing to prevent text blur in adjacent NSTextView
final class LineNumberView: NSView {
    // MARK: - Properties

    private weak var textView: NSTextView?
    private weak var scrollView: NSScrollView?

    /// Cached line start indices (character positions)
    private var lineStartIndices: [Int] = [0]

    /// Last known text length (to detect changes)
    private var lastTextLength: Int = 0

    /// Current width of the view
    private var currentWidth: CGFloat = SQLEditorTheme.lineNumberRulerMinThickness

    // MARK: - Initialization

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        self.scrollView = scrollView
        super.init(frame: .zero)

        // CRITICAL: Do not use layer-backed rendering to prevent blur
        self.wantsLayer = false

        // Observe text changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )

        // Observe scroll/bounds changes for synchronization
        let clipView = scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: clipView
        )

        // Initial cache build
        updateLineCache(for: textView.string)
        updateWidth()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Layout

    /// Use flipped coordinates (top-left origin) to match NSTextView
    override var isFlipped: Bool {
        true
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: currentWidth, height: NSView.noIntrinsicMetric)
    }

    // MARK: - Notifications

    @objc private func textDidChange(_ notification: Notification) {
        guard let textView = textView else { return }
        updateLineCache(for: textView.string)
        updateWidth()
        needsDisplay = true
    }

    @objc private func boundsDidChange(_ notification: Notification) {
        // Scroll synchronization happens via coordinator in container
        needsDisplay = true
    }

    // MARK: - Line Cache Management

    /// Update cached line start indices
    private func updateLineCache(for text: String) {
        // If text is empty, reset to single line
        guard !text.isEmpty else {
            lineStartIndices = [0]
            lastTextLength = 0
            return
        }

        // If length changed significantly, rebuild cache
        let textLength = text.count
        if abs(textLength - lastTextLength) > 100 || lineStartIndices.isEmpty {
            rebuildLineCache(for: text)
        } else {
            // For simplicity, rebuild (still fast for typical edits)
            rebuildLineCache(for: text)
        }

        lastTextLength = textLength
    }

    /// Rebuild line cache from scratch
    private func rebuildLineCache(for text: String) {
        lineStartIndices = [0]

        for (index, char) in text.enumerated() {
            if char == "\n" {
                lineStartIndices.append(index + 1)
            }
        }
    }

    /// Update view width based on line count
    private func updateWidth() {
        let lineCount = lineStartIndices.count
        let digits = max(2, String(lineCount).count)
        let newWidth = CGFloat(digits * 8 + 16)

        if currentWidth != newWidth {
            currentWidth = newWidth
            invalidateIntrinsicContentSize()
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Draw background
        SQLEditorTheme.lineNumberBackground.setFill()
        dirtyRect.fill()

        // Draw right border
        SQLEditorTheme.lineNumberBorder.setStroke()
        let borderPath = NSBezierPath()
        borderPath.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        borderPath.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        borderPath.lineWidth = 1
        borderPath.stroke()

        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let scrollView = scrollView else { return }

        let text = textView.string

        // Handle empty document
        guard !text.isEmpty else {
            drawLineNumber(1, at: textView.textContainerOrigin.y)
            return
        }

        // Get visible rect from scroll view
        let visibleRect = scrollView.contentView.bounds
        let textContainerOrigin = textView.textContainerOrigin

        // Ensure layout
        layoutManager.ensureLayout(for: textContainer)

        guard layoutManager.numberOfGlyphs > 0 else { return }

        // Get visible glyph range
        let visibleGlyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        guard visibleGlyphRange.location != NSNotFound else { return }

        // Get character range for visible glyphs
        let visibleCharRange = layoutManager.characterRange(forGlyphRange: visibleGlyphRange, actualGlyphRange: nil)

        // Find first visible line using binary search on cached indices
        let firstVisibleLine = lineStartIndices.lastIndex { $0 <= visibleCharRange.location } ?? 0

        // Draw line numbers for visible lines
        var lineNumber = firstVisibleLine + 1
        var currentIndex = firstVisibleLine
        var lastDrawnY: CGFloat = -1_000 // Track last Y position to avoid duplicates

        while currentIndex < lineStartIndices.count {
            let lineStart = lineStartIndices[currentIndex]

            // Stop if we've gone past visible range
            if lineStart >= NSMaxRange(visibleCharRange) {
                break
            }

            // Get glyph index for this line
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineStart)
            guard glyphIndex < layoutManager.numberOfGlyphs else { break }

            // Get line fragment rect (this gives us the first line fragment for wrapped lines)
            var effectiveRange = NSRange()
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &effectiveRange)

            // Calculate Y position in line number view coordinates
            // Pixel-align for crisp rendering
            let yPos = floor(lineRect.origin.y + textContainerOrigin.y - visibleRect.origin.y)

            // Only draw if this is a new Y position (avoid drawing for wrapped line fragments)
            if abs(yPos - lastDrawnY) > 1.0 {
                drawLineNumber(lineNumber, at: yPos)
                lastDrawnY = yPos
            }

            lineNumber += 1
            currentIndex += 1
        }
    }

    /// Draw a single line number at the specified Y position
    private func drawLineNumber(_ number: Int, at yPosition: CGFloat) {
        let string = "\(number)"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: SQLEditorTheme.lineNumberFont,
            .foregroundColor: SQLEditorTheme.lineNumberText
        ]

        let size = string.size(withAttributes: attributes)
        let xPos = currentWidth - size.width - 8
        // Pixel-align Y position for crisp text
        let yPos = floor(yPosition + (17 - size.height) / 2)

        string.draw(at: NSPoint(x: xPos, y: yPos), withAttributes: attributes)
    }
}
