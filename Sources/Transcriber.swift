import AVFoundation
import Speech

/// One piece of transcription output, normalised across SpeechTranscriber / DictationTranscriber.
struct Piece: Sendable {
    let text: String
    let isFinal: Bool
}

enum DictateError: LocalizedError {
    case noAudioFormat
    case micDenied
    case modelUnsupported(String)
    case noMicrophone
    case micChanged

    var errorDescription: String? {
        switch self {
        case .noAudioFormat: return "No compatible audio format for the speech model."
        case .micDenied: return "Microphone access denied. Enable it in System Settings → Privacy → Microphone."
        case .modelUnsupported(let id): return "Apple's speech model doesn't support \(id) on this Mac."
        case .noMicrophone: return "No microphone found."
        case .micChanged: return "Microphone changed while starting. Try again."
        }
    }
}

/// Thin wrapper around Apple's built-in, on-device speech models.
/// Which Apple model to use, and for which locale.
struct SpeechConfig: Sendable {
    let locale: Locale
    let useSpeechTranscriber: Bool
    static let fallback = SpeechConfig(locale: Locale(identifier: "en-US"), useSpeechTranscriber: SpeechTranscriber.isAvailable)
}

enum SpeechEngine {
    static func resolve() async -> SpeechConfig {
        if SpeechTranscriber.isAvailable,
           let l = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return SpeechConfig(locale: l, useSpeechTranscriber: true)
        }
        if let l = await DictationTranscriber.supportedLocale(equivalentTo: Locale.current) {
            return SpeechConfig(locale: l, useSpeechTranscriber: false)
        }
        return .fallback
    }

    static func makeModule(_ config: SpeechConfig) -> any SpeechModule {
        let locale = config.locale
        if config.useSpeechTranscriber {
            return SpeechTranscriber(locale: locale,
                                     transcriptionOptions: [],
                                     reportingOptions: [.volatileResults],
                                     attributeOptions: [])
        }
        return DictationTranscriber(locale: locale, preset: .progressiveLongDictation)
    }

    /// Makes sure Apple's on-device model for `locale` is installed (one-time, OS-managed).
    static func ensureAssets(_ config: SpeechConfig, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let locale = config.locale
        let module = makeModule(config)
        let status = await AssetInventory.status(forModules: [module])
        if status == .installed { return }
        if status == .unsupported { throw DictateError.modelUnsupported(locale.identifier) }
        _ = try? await AssetInventory.reserve(locale: locale)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            let obs = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
                progress?(p.fractionCompleted)
            }
            defer { obs.invalidate() }
            try await request.downloadAndInstall()
        }
    }

    static func pieces(of module: any SpeechModule) -> AsyncThrowingStream<Piece, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                do {
                    if let t = module as? SpeechTranscriber {
                        for try await r in t.results {
                            cont.yield(Piece(text: String(r.text.characters), isFinal: r.isFinal))
                        }
                    } else if let t = module as? DictationTranscriber {
                        for try await r in t.results {
                            cont.yield(Piece(text: String(r.text.characters), isFinal: r.isFinal))
                        }
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

/// Converts audio buffers into the model's format and feeds them to the analyzer.
/// Lives outside the main actor because the audio tap runs on a realtime thread.
final class AudioFeeder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let target: AVAudioFormat
    private let cont: AsyncStream<AnalyzerInput>.Continuation

    init?(from source: AVAudioFormat, to target: AVAudioFormat, cont: AsyncStream<AnalyzerInput>.Continuation) {
        guard let c = AVAudioConverter(from: source, to: target) else { return nil }
        converter = c
        self.target = target
        self.cont = cont
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
        var consumed = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status != .error, out.frameLength > 0 {
            cont.yield(AnalyzerInput(buffer: out))
        }
    }

    func installTap(on node: AVAudioInputNode, format: AVAudioFormat) {
        node.installTap(onBus: 0, bufferSize: 4096, format: format) { [self] buffer, _ in
            self.feed(buffer)
        }
    }

    /// Flushes samples still buffered inside the sample-rate converter, then closes the stream.
    /// Call only after the tap is removed (no concurrent `feed`).
    func finish() {
        for _ in 0..<4 {
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096) else { break }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }
            if out.frameLength > 0 { cont.yield(AnalyzerInput(buffer: out)) }
            if status != .haveData { break }
        }
        cont.finish()
    }
}

/// One dictation session at a time: mic → converter → SpeechAnalyzer → live text.
@MainActor
final class Transcriber {
    var onUpdate: ((String) -> Void)?
    /// Called if recognition or audio capture dies mid-session (e.g. mic unplugged).
    var onFailure: ((String) -> Void)?

    private var configObserver: NSObjectProtocol?
    private var finalized = ""
    private var volatile = ""
    private var analyzer: SpeechAnalyzer?
    private var feeder: AudioFeeder?
    private var resultsTask: Task<Void, Never>?
    private var engine: AVAudioEngine?

    var currentText: String { Self.join(finalized, volatile) }

    /// Starts listening to the microphone.
    func start(_ config: SpeechConfig) async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw DictateError.micDenied }
        default: throw DictateError.micDenied
        }

        try await SpeechEngine.ensureAssets(config)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let micFormat = input.outputFormat(forBus: 0)
        guard micFormat.sampleRate > 0, micFormat.channelCount > 0 else { throw DictateError.noMicrophone }
        try await begin(config, sourceFormat: micFormat)
        // The mic may have changed while we awaited; a stale format would raise an ObjC exception.
        let nowFormat = input.outputFormat(forBus: 0)
        guard nowFormat.sampleRate == micFormat.sampleRate, nowFormat.channelCount == micFormat.channelCount else {
            _ = await stop()
            throw DictateError.micChanged
        }
        feeder!.installTap(on: input, format: micFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            _ = await stop()
            throw error
        }
        self.engine = engine
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onFailure?("Microphone changed, so dictation stopped.") }
        }
    }

    /// Sets up the analyzer for audio arriving in `sourceFormat`.
    func begin(_ config: SpeechConfig, sourceFormat: AVAudioFormat) async throws {
        finalized = ""
        volatile = ""
        let module = SpeechEngine.makeModule(config)
        guard let modelFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module],
                                                                             considering: sourceFormat)
        else { throw DictateError.noAudioFormat }

        let (stream, cont) = AsyncStream.makeStream(of: AnalyzerInput.self)
        guard let feeder = AudioFeeder(from: sourceFormat, to: modelFormat, cont: cont) else {
            throw DictateError.noAudioFormat
        }
        let analyzer = SpeechAnalyzer(modules: [module])
        try await analyzer.prepareToAnalyze(in: modelFormat)

        let pieces = SpeechEngine.pieces(of: module)
        resultsTask = Task { @MainActor [weak self] in
            do {
                for try await p in pieces {
                    guard let self else { return }
                    if p.isFinal {
                        self.finalized = Self.join(self.finalized, p.text)
                        self.volatile = ""
                    } else {
                        self.volatile = p.text
                    }
                    self.onUpdate?(self.currentText)
                }
            } catch {
                NSLog("Dictate: results error \(error)")
                if !(error is CancellationError) {
                    self?.onFailure?("Speech recognition stopped: \(error.localizedDescription)")
                }
            }
        }

        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        self.feeder = feeder
    }

    /// Feeds a buffer directly (used by the file self-test).
    func feed(_ buffer: AVAudioPCMBuffer) { feeder?.feed(buffer) }

    /// Stops listening, waits for the model to finalise the last words, returns the full text.
    func stop() async -> String {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        configObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        feeder?.finish()
        feeder = nil
        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            NSLog("Dictate: finalize error \(error)")
            await analyzer?.cancelAndFinishNow()
        }
        await resultsTask?.value
        analyzer = nil
        resultsTask = nil
        return currentText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func join(_ a: String, _ b: String) -> String {
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        if a.last!.isWhitespace || b.first!.isWhitespace { return a + b }
        return a + " " + b
    }
}

/// `Dictate --transcribe file.aiff` — runs an audio file through the same pipeline and prints the text.
@MainActor
func runFileSelfTest(path: String) async -> Int32 {
    do {
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let config = await SpeechEngine.resolve()
        FileHandle.standardError.write("locale: \(config.locale.identifier), SpeechTranscriber: \(config.useSpeechTranscriber)\n".data(using: .utf8)!)
        try await SpeechEngine.ensureAssets(config) { p in
            FileHandle.standardError.write("model download: \(Int(p * 100))%\n".data(using: .utf8)!)
        }
        let t = Transcriber()
        t.onUpdate = { FileHandle.standardError.write("… \($0)\n".data(using: .utf8)!) }
        let format = file.processingFormat
        try await t.begin(config, sourceFormat: format)
        while file.framePosition < file.length {
            guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { break }
            try file.read(into: buf)
            if buf.frameLength == 0 { break }
            t.feed(buf)
        }
        let text = await t.stop()
        print(text)
        return text.isEmpty ? 1 : 0
    } catch {
        FileHandle.standardError.write("error: \(error.localizedDescription)\n".data(using: .utf8)!)
        return 2
    }
}
