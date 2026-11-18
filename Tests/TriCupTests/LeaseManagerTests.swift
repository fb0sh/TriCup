import XCTest
import Foundation
@testable import TriCupCore

private final class FakeSleepSetting: SleepDisabledSetting {
    var value: Bool
    var failReads = false
    var failAllWrites = false
    var failWritesRemaining = 0
    var ignoreWrites = false
    private(set) var writeCount = 0

    init(_ value: Bool) {
        self.value = value
    }

    func readSleepDisabled() throws -> Bool {
        if failReads { throw PowerError("read failed") }
        return value
    }

    func writeSleepDisabled(_ disabled: Bool) throws {
        writeCount += 1
        if failAllWrites { throw PowerError("write failed") }
        if failWritesRemaining > 0 {
            failWritesRemaining -= 1
            throw PowerError("write failed")
        }
        if !ignoreWrites {
            value = disabled
        }
    }
}

private final class MemoryLeaseStore: LeaseStoring {
    var record: LeaseRecord?
    var failSave = false
    var loadError: Error?

    func load() throws -> LeaseRecord? {
        if let loadError = loadError { throw loadError }
        return record
    }

    func save(_ record: LeaseRecord) throws {
        if failSave { throw PowerError("save failed") }
        self.record = record
    }

    func clear() throws { record = nil }
}

final class LeaseManagerTests: XCTestCase {
    private func makeManager(
        _ setting: FakeSleepSetting,
        _ store: MemoryLeaseStore = MemoryLeaseStore()
    ) -> LeaseManager {
        LeaseManager(setting: setting, store: store)
    }

    func testEnableRecordsOriginalAndPersistsBeforeWrite() throws {
        let setting = FakeSleepSetting(false)
        let store = MemoryLeaseStore()
        let manager = LeaseManager(setting: setting, store: store)

        try manager.enable()

        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(setting.value)
        XCTAssertEqual(store.record?.originalSleepDisabled, false)
    }

    func testPersistenceFailureDoesNotModifySetting() {
        let setting = FakeSleepSetting(false)
        let store = MemoryLeaseStore()
        store.failSave = true
        let manager = LeaseManager(setting: setting, store: store)

        XCTAssertThrowsError(try manager.enable())
        XCTAssertEqual(setting.writeCount, 0)
        XCTAssertFalse(setting.value)
    }

    func testApplyFailureRollsBackAndClearsRecord() {
        let setting = FakeSleepSetting(false)
        setting.failWritesRemaining = 1 // first write fails, rollback write succeeds
        let store = MemoryLeaseStore()
        let manager = LeaseManager(setting: setting, store: store)

        XCTAssertThrowsError(try manager.enable())
        XCTAssertFalse(setting.value)
        XCTAssertNil(store.record)
        XCTAssertFalse(manager.isActive)
    }

    func testVerificationFailureRollsBack() {
        let setting = FakeSleepSetting(false)
        setting.ignoreWrites = true // writes are accepted but value never changes
        let store = MemoryLeaseStore()
        let manager = LeaseManager(setting: setting, store: store)

        XCTAssertThrowsError(try manager.enable())
        XCTAssertFalse(setting.value)
        XCTAssertNil(store.record)
    }

    func testOnlyOneLeaseAllowed() throws {
        let setting = FakeSleepSetting(false)
        let manager = makeManager(setting)
        try manager.enable()
        XCTAssertThrowsError(try manager.enable()) { error in
            XCTAssertEqual(error as? LeaseError, .alreadyActive)
        }
    }

    func testDisableRestoresOriginalAndClearsRecord() throws {
        let setting = FakeSleepSetting(false)
        let store = MemoryLeaseStore()
        let manager = LeaseManager(setting: setting, store: store)
        try manager.enable()

        try manager.disable()

        XCTAssertFalse(setting.value)
        XCTAssertNil(store.record)
        XCTAssertFalse(manager.isActive)
    }

    func testDisableIsIdempotent() throws {
        let setting = FakeSleepSetting(false)
        let manager = makeManager(setting)
        try manager.enable()
        try manager.disable()
        XCTAssertNoThrow(try manager.disable()) // second call is a no-op
    }

    func testRestoreFailureKeepsRecord() throws {
        let setting = FakeSleepSetting(false)
        let store = MemoryLeaseStore()
        let manager = LeaseManager(setting: setting, store: store)
        try manager.enable()

        setting.failAllWrites = true
        XCTAssertThrowsError(try manager.disable())
        XCTAssertEqual(store.record?.originalSleepDisabled, false) // record kept

        // Recovery after the fault clears up.
        setting.failAllWrites = false
        try manager.recoverOnStartup()
        XCTAssertFalse(setting.value)
        XCTAssertNil(store.record)
    }

    func testRecoverOnStartupRestoresResidualLease() throws {
        let setting = FakeSleepSetting(false)
        let store = MemoryLeaseStore()
        // Simulate a previous run that left SleepDisabled on.
        store.record = LeaseRecord(originalSleepDisabled: false)
        setting.value = true

        let manager = LeaseManager(setting: setting, store: store)
        try manager.recoverOnStartup()

        XCTAssertFalse(setting.value)
        XCTAssertNil(store.record)
    }

    func testRecoverIsIdempotentWithNoRecord() throws {
        let manager = makeManager(FakeSleepSetting(false))
        XCTAssertNoThrow(try manager.recoverOnStartup())
        XCTAssertNoThrow(try manager.recoverOnStartup())
    }

    func testRestorePreservesPriorTrueSetting() throws {
        // SleepDisabled was already true before TriCup; restoring must keep it true.
        let setting = FakeSleepSetting(true)
        let store = MemoryLeaseStore()
        let manager = LeaseManager(setting: setting, store: store)
        try manager.enable()
        try manager.disable()
        XCTAssertTrue(setting.value)
        XCTAssertNil(store.record)
    }

    func testRestoreRetriesThenSucceeds() throws {
        let setting = FakeSleepSetting(false)
        let store = MemoryLeaseStore()
        let manager = LeaseManager(setting: setting, store: store, maxRestoreAttempts: 3)
        try manager.enable()

        setting.failWritesRemaining = 2 // first two restore writes fail, third works
        try manager.disable()
        XCTAssertFalse(setting.value)
        XCTAssertNil(store.record)
    }

    func testFileLeaseStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tricup-lease-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("lease.json")
        let store = FileLeaseStore(url: url)

        XCTAssertNil(try store.load())
        let record = LeaseRecord(originalSleepDisabled: true)
        try store.save(record)
        XCTAssertEqual(try store.load()?.originalSleepDisabled, true)
        try store.clear()
        XCTAssertNil(try store.load())
    }

    func testDisableSurfacesStoreLoadError() {
        let store = MemoryLeaseStore()
        store.loadError = PowerError("read boom")
        let manager = LeaseManager(setting: FakeSleepSetting(false), store: store)

        XCTAssertThrowsError(try manager.disable()) { error in
            guard let leaseError = error as? LeaseError, case .persistenceFailed(_) = leaseError else {
                return XCTFail("expected persistenceFailed, got \(error)")
            }
        }
    }

    private func temporaryStore() -> (FileLeaseStore, URL, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tricup-lease-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("lease.json")
        return (FileLeaseStore(url: url), url, dir)
    }

    func testEmptyLeaseFileIsError() throws {
        let (store, url, dir) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data().write(to: url)

        XCTAssertThrowsError(try store.load()) { error in
            guard let leaseError = error as? LeaseError, case .persistenceFailed(_) = leaseError else {
                return XCTFail("expected persistenceFailed, got \(error)")
            }
        }
    }

    func testCorruptLeaseJSONIsError() throws {
        let (store, url, dir) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{not valid json".utf8).write(to: url)

        XCTAssertThrowsError(try store.load()) { error in
            guard let leaseError = error as? LeaseError, case .persistenceFailed(_) = leaseError else {
                return XCTFail("expected persistenceFailed, got \(error)")
            }
        }
    }

    func testUnsupportedLeaseVersionIsError() throws {
        let (store, url, dir) = temporaryStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"originalSleepDisabled":false,"createdAt":0,"schemaVersion":99}"#
        try Data(json.utf8).write(to: url)

        XCTAssertThrowsError(try store.load()) { error in
            guard let leaseError = error as? LeaseError, case .persistenceFailed(_) = leaseError else {
                return XCTFail("expected persistenceFailed, got \(error)")
            }
        }
    }

    func testOriginalSleepDisabledTrueIsRestoredAsTrue() throws {
        let setting = FakeSleepSetting(true)
        let store = MemoryLeaseStore()
        let manager = LeaseManager(setting: setting, store: store)
        try manager.enable()
        try manager.disable()
        XCTAssertTrue(setting.value)
        XCTAssertNil(store.record)
    }
}
