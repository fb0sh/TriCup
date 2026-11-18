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
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LeaseError.persistenceFailed("cannot read lease file: \(error)")
        }
        guard !data.isEmpty else {
            // An existing but empty file is corruption, not "no lease": refusing
            // to continue protects against unsafe new leases / lost recovery data.
            throw LeaseError.persistenceFailed("lease file is empty")
        }
        let record: LeaseRecord
        do {
            record = try JSONDecoder().decode(LeaseRecord.self, from: data)
        } catch {
            throw LeaseError.persistenceFailed("corrupt lease JSON: \(error)")
        }
        guard record.schemaVersion == LeaseRecord.supportedSchemaVersion else {
            throw LeaseError.persistenceFailed("unsupported lease schemaVersion \(record.schemaVersion)")
        }
        return record
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
