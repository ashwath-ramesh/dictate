import AppKit
import ApplicationServices

@MainActor
enum Paster {
    /// Clipboard contents from before our first un-restored paste (so back-to-back pastes restore the original).
    private static var pendingSnapshot: [[(NSPasteboard.PasteboardType, Data)]]?
    private static var restoreWork: DispatchWorkItem?
    private static var pendingChangeCount = -1

    static var hasAccessibility: Bool { AXIsProcessTrusted() }

    static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func copy(_ text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Pastes `text` at the cursor of the frontmost app, then restores the previous clipboard.
    /// Returns false (text left on the clipboard) if Accessibility permission is missing.
    @discardableResult
    static func paste(_ text: String) -> Bool {
        let pb = NSPasteboard.general
        guard hasAccessibility else {
            copy(text)
            return false
        }

        // Snapshot the current clipboard so we can put it back (reuse the original if a restore is pending).
        restoreWork?.cancel()
        let reusable = pb.changeCount == pendingChangeCount ? pendingSnapshot : nil
        let saved = reusable ?? (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { t in item.data(forType: t).map { (t, $0) } }
        }
        pendingSnapshot = saved

        pb.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        // Hint to clipboard managers that this is a transient entry.
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pb.writeObjects([item])
        let ourChange = pb.changeCount
        pendingChangeCount = ourChange

        let src = CGEventSource(stateID: .hidSystemState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Give the target app time to read the clipboard before restoring it.
        let work = DispatchWorkItem {
            pendingSnapshot = nil
            restoreWork = nil
            // If something else touched the clipboard since, leave it alone.
            guard pb.changeCount == ourChange else { return }
            pb.clearContents()
            let items = saved.map { pairs in
                let it = NSPasteboardItem()
                for (type, data) in pairs { it.setData(data, forType: type) }
                return it
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        restoreWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        return true
    }
}
