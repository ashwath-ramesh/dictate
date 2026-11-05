import AppKit

/// Floating HUD at the bottom of the screen showing live text. Never takes focus.
@MainActor
final class Overlay {
    private let panel: NSPanel
    private let label: NSTextField
    private let dot: NSTextField
    private var hideWork: DispatchWorkItem?
    private let size = NSSize(width: 620, height: 96)

    init() {
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow
        bg.blendingMode = .behindWindow
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 16
        bg.layer?.masksToBounds = true
        bg.autoresizingMask = [.width, .height]

        dot = NSTextField(labelWithString: "●")
        dot.textColor = .systemRed
        dot.font = .systemFont(ofSize: 18)
        dot.frame = NSRect(x: 16, y: size.height - 38, width: 22, height: 24)

        label = NSTextField(wrappingLabelWithString: "")
        label.font = .systemFont(ofSize: 15, weight: .medium)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 3
        label.frame = NSRect(x: 44, y: 12, width: size.width - 60, height: size.height - 24)

        bg.addSubview(dot)
        bg.addSubview(label)
        panel.contentView = bg
    }

    /// Shows the panel with `text`. `recording` toggles the red dot.
    func show(_ text: String, recording: Bool = true) {
        hideWork?.cancel()
        hideWork = nil
        dot.textColor = recording ? .systemRed : .systemGray
        // Show only the tail so the latest words are always visible.
        let maxChars = 220
        label.stringValue = text.count > maxChars ? "…" + String(text.suffix(maxChars)) : text
        if !panel.isVisible { position() }
        panel.orderFrontRegardless()
    }

    /// Shows a short message, then hides automatically.
    func flash(_ text: String, seconds: Double = 2.5) {
        show(text, recording: false)
        hide(after: seconds)
    }

    func hide(after seconds: Double = 0) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.panel.orderOut(nil) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let f = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 60))
    }
}
