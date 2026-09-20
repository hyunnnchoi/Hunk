import Foundation

/// Keeps one review session per repository and scope under Application Support.
struct FileSessionArchive: SessionArchive {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Hunk/sessions", isDirectory: true)
    }

    private func url(_ key: String) -> URL {
        directory.appendingPathComponent(UUID(hashing: key).uuidString + ".json")
    }

    func load(key: String) -> SessionRecord? {
        guard let data = try? Data(contentsOf: url(key)) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(SessionRecord.self, from: data)
    }

    func save(_ record: SessionRecord, key: String) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: url(key), options: .atomic)
    }
}
