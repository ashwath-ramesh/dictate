import AppKit
import AVFoundation

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State { case idle, starting, recording, finishing }

    private var statusItem: NSStatusItem!
    private let overlay = Overlay()
    private let history = History()
    private let transcriber = Transcriber()
    private var hotkey: RightOptionTap?
    private var state = State.idle
    private var stopRequestedWhileStarting = false
    private var config = SpeechConfig.fallback
    private var pasteTarget: pid_t?
    private var modelStatus = "Checking Apple speech model…"

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        transcriber.onUpdate = { [weak self] text in
            guard let self, self.state == .recording || self.state == .finishing else { return }
            self.overlay.show(text.isEmpty ? "Listening…" : text)
        }
        transcriber.onFailure = { [weak self] message in
            guard let self, self.state == .recording else { return }
            self.finishDictation(note: message)
        }
        hotkey = RightOptionTap { [weak self] in
            DispatchQueue.main.async { self?.toggle() }
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
        }
        if !Paster.hasAccessibility { Paster.promptForAccessibility() }

        Task { await prepareModel() }
    }

    private func prepareModel() async {
        config = await SpeechEngine.resolve()
        do {
            try await SpeechEngine.ensureAssets(config) { [weak self] p in
                Task { @MainActor in
                    self?.modelStatus = "Downloading Apple speech model… \(Int(p * 100))%"
                }
            }
            modelStatus = "Apple on-device model ready (\(config.locale.identifier))"
        } catch {
            modelStatus = "Model error: \(error.localizedDescription)"
        }
    }

    // MARK: Dictation flow

    @objc func toggle() {
        switch state {
        case .idle: startDictation()
        case .starting: stopRequestedWhileStarting = true
        case .recording: finishDictation()
        case .finishing: break
        }
    }

    private func startDictation() {
        state = .starting
        stopRequestedWhileStarting = false
        updateIcon()
        overlay.show("Preparing…", recording: false)
        Task {
            do {
                try await transcriber.start(config)
                state = .recording
                updateIcon()
                overlay.show("Listening…")
                if stopRequestedWhileStarting { finishDictation() }
            } catch {
                state = .idle
                updateIcon()
                overlay.flash(error.localizedDescription, seconds: 4)
            }
        }
    }

    private func finishDictation(note: String? = nil) {
        // Remember which app should receive the paste; if focus moves during finalisation we won't paste.
        pasteTarget = NSWorkspace.shared.frontmostApplication?.processIdentifier
        state = .finishing
        updateIcon()
        overlay.show(transcriber.currentText.isEmpty ? "Finishing…" : transcriber.currentText, recording: false)
        Task {
            let text = await transcriber.stop()
            state = .idle
            updateIcon()
            guard !text.isEmpty else {
                overlay.flash(note ?? "Didn't catch anything", seconds: note == nil ? 2.5 : 4)
                return
            }
            history.add(text)
            if NSWorkspace.shared.frontmostApplication?.processIdentifier != pasteTarget {
                Paster.copy(text)
                overlay.flash("You switched apps, so the text was copied (⌘V to paste).", seconds: 4)
                return
            }
            if let note {
                overlay.flash(note, seconds: 4)
            } else {
                overlay.hide()
            }
            if !Paster.paste(text) {
                overlay.flash("Copied to clipboard. Grant Accessibility to Dictate to auto-paste.", seconds: 4)
                Paster.promptForAccessibility()
            }
        }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let active = state != .idle
        button.image = NSImage(systemSymbolName: active ? "mic.fill" : "mic",
                               accessibilityDescription: "Dictate")
        button.contentTintColor = active ? .systemRed : nil
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title: String
        switch state {
        case .idle: title = "Start Dictation (tap Right ⌥)"
        case .starting, .recording: title = "Stop & Paste (tap Right ⌥)"
        case .finishing: title = "Finishing…"
        }
        menu.addItem(withTitle: title, action: #selector(toggle), keyEquivalent: "").target = self

        let status = NSMenuItem(title: modelStatus, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        if !Paster.hasAccessibility {
            menu.addItem(withTitle: "⚠︎ Grant Accessibility (needed for hotkey + paste)…",
                         action: #selector(openAccessibility), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())

        let recent = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if history.entries.isEmpty {
            let empty = NSMenuItem(title: "None yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            sub.addItem(empty)
        }
        for entry in history.entries.prefix(10) {
            let short = entry.text.count > 60 ? String(entry.text.prefix(60)) + "…" : entry.text
            let item = NSMenuItem(title: short, action: #selector(copyEntry(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.text
            item.toolTip = "Click to copy\n\n" + entry.text
            sub.addItem(item)
        }
        recent.submenu = sub
        menu.addItem(recent)
        menu.addItem(withTitle: "Open History File", action: #selector(openHistory), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Dictate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func copyEntry(_ sender: NSMenuItem) {
        if let text = sender.representedObject as? String { Paster.copy(text) }
    }

    @objc private func openHistory() {
        NSWorkspace.shared.activateFileViewerSelecting([history.url])
    }

    @objc private func openAccessibility() {
        Paster.promptForAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: Entry point

let args = CommandLine.arguments
if args.count >= 3, args[1] == "--transcribe" {
    Task { @MainActor in exit(await runFileSelfTest(path: args[2])) }
    dispatchMain()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
