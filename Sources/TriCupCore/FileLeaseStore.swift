import Foundation

/// File-backed `LeaseStoring` that writes a single JSON record atomically.
public final class FileLeaseStore: LeaseStoring {
    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() throws -> LeaseRecord? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            return nil
        }
        return try JSONDecoder().decode(LeaseRecord.self, from: data)
    }

    public func save(_ record: LeaseRecord) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: .atomic)
    }

    public func clear() throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return
        }
        try FileManager.default.removeItem(at: url)
    }
}
