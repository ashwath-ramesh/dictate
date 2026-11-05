import Foundation

struct HistoryEntry: Codable {
    let date: Date
    let text: String
}

/// Recent transcripts, newest first, saved to ~/Library/Application Support/Dictate/history.json.
final class History {
    private(set) var entries: [HistoryEntry] = []
    private let limit = 100
    let url: URL

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dictate", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: url),
           let decoded = try? Self.decoder.decode([HistoryEntry].self, from: data) {
            entries = decoded
        }
    }

    func add(_ text: String) {
        entries.insert(HistoryEntry(date: Date(), text: text), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
        save()
    }

    private func save() {
        do {
            let data = try Self.encoder.encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("Dictate: failed to save history \(error)")
        }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
