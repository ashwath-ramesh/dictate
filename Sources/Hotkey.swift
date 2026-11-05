import AppKit

/// Fires `onTap` when Right Option is pressed and released on its own (no other key in between).
/// Holding Right Option to type special characters (⌥E etc.) does not trigger it.
final class RightOptionTap {
    private static let rightOptionKeyCode: UInt16 = 61
    private static let rightAltMask: UInt = 0x40  // NX_DEVICERALTKEYMASK
    private static let leftAltMask: UInt = 0x20   // NX_DEVICELALTKEYMASK
    private static let maxTapDuration: TimeInterval = 0.5

    private let onTap: () -> Void
    private var downAt: TimeInterval?
    private var dirty = false
    private var monitors: [Any] = []

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let g = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(g)
        }
        if let l = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] e in self?.handle(e); return e }) {
            monitors.append(l)
        }
    }

    deinit { monitors.forEach(NSEvent.removeMonitor) }

    private func handle(_ e: NSEvent) {
        if e.type == .keyDown {
            if downAt != nil { dirty = true }
            return
        }
        guard e.type == .flagsChanged else { return }
        let raw = e.modifierFlags.rawValue
        if e.keyCode == Self.rightOptionKeyCode {
            if raw & Self.rightAltMask != 0 {
                // Right Option went down.
                downAt = e.timestamp
                let others: NSEvent.ModifierFlags = [.command, .control, .shift, .function]
                dirty = !e.modifierFlags.intersection(others).isEmpty || raw & Self.leftAltMask != 0
            } else if let d = downAt {
                // Right Option went up.
                downAt = nil
                if !dirty && e.timestamp - d <= Self.maxTapDuration { onTap() }
            }
        } else if downAt != nil {
            // Some other modifier changed while Right Option is held → it's a chord, not a tap.
            dirty = true
        }
    }
}
