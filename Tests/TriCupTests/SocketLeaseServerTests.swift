import XCTest
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import TriCupCore

private final class SocketFakeSetting: SleepDisabledSetting {
    var value: Bool
    init(_ value: Bool) { self.value = value }
    func readSleepDisabled() throws -> Bool { value }
    func writeSleepDisabled(_ disabled: Bool) throws { value = disabled }
}

private final class SocketMemoryStore: LeaseStoring {
    var record: LeaseRecord?
    func load() throws -> LeaseRecord? { record }
    func save(_ record: LeaseRecord) throws { self.record = record }
    func clear() throws { record = nil }
}

final class SocketLeaseServerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Some tests intentionally write to a closed peer; never let that kill
        // the test process with SIGPIPE.
        signal(SIGPIPE, SIG_IGN)
    }

    private func makeSocketPath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("tricup-\(UUID().uuidString.prefix(8)).sock")
            .path
    }

    private func openConnection(_ path: String) -> Int32? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let base = raw.bindMemory(to: UInt8.self)
            for (index, value) in bytes.enumerated() {
                base[index] = value
            }
            base[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        if result != 0 {
            close(fd)
            return nil
        }
        return fd
    }

    private func send(_ fd: Int32, _ line: String) {
        let data = Data((line + "\n").utf8)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = write(fd, base, raw.count)
        }
    }

    private func readLine(_ fd: Int32) -> String {
        var bytes = [UInt8]()
        var byte: UInt8 = 0
        while read(fd, &byte, 1) > 0 {
            if byte == 0x0A { break }
            bytes.append(byte)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private func waitUntil(_ timeout: TimeInterval = 2.0, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    func testEnableThenDisconnectRestores() throws {
        let path = makeSocketPath()
        let setting = SocketFakeSetting(false)
        let store = SocketMemoryStore()
        let manager = LeaseManager(setting: setting, store: store)
        let server = SocketLeaseServer(socketPath: path, manager: manager) { _ in true }
        try server.start()
        defer { server.stop() }

        guard let fd = openConnection(path) else {
            return XCTFail("could not connect to \(path)")
        }

        send(fd, "enable")
        XCTAssertEqual(readLine(fd), "OK enabled")
        XCTAssertTrue(manager.isActive)
        XCTAssertTrue(setting.value)

        close(fd) // simulate app quit / crash
        XCTAssertTrue(waitUntil { setting.value == false }, "lease was not restored on disconnect")
        XCTAssertFalse(manager.isActive)
    }

    func testStatusAndUnknownCommand() throws {
        let path = makeSocketPath()
        let setting = SocketFakeSetting(false)
        let manager = LeaseManager(setting: setting, store: SocketMemoryStore())
        let server = SocketLeaseServer(socketPath: path, manager: manager) { _ in true }
        try server.start()
        defer { server.stop() }

        guard let fd = openConnection(path) else {
            return XCTFail("could not connect")
        }

        send(fd, "status")
        XCTAssertEqual(readLine(fd), "OK inactive")

        send(fd, "rm -rf /")
        XCTAssertEqual(readLine(fd), "ERR unknown_command")

        send(fd, "enable")
        XCTAssertEqual(readLine(fd), "OK enabled")

        send(fd, "status")
        XCTAssertEqual(readLine(fd), "OK active")

        send(fd, "disable")
        XCTAssertEqual(readLine(fd), "OK disabled")
        close(fd)
    }

    func testSecondLeaseIsRejected() throws {
        let path = makeSocketPath()
        let setting = SocketFakeSetting(false)
        let manager = LeaseManager(setting: setting, store: SocketMemoryStore())
        let server = SocketLeaseServer(socketPath: path, manager: manager) { _ in true }
        try server.start()
        defer { server.stop() }

        guard let first = openConnection(path), let second = openConnection(path) else {
            return XCTFail("could not connect")
        }
        defer { close(first); close(second) }

        send(first, "enable")
        XCTAssertEqual(readLine(first), "OK enabled")

        send(second, "enable")
        XCTAssertTrue(readLine(second).hasPrefix("ERR"), "second lease should be rejected")
    }

    func testOversizedCommandDoesNotKillServer() throws {
        let path = makeSocketPath()
        let setting = SocketFakeSetting(false)
        let manager = LeaseManager(setting: setting, store: SocketMemoryStore())
        let server = SocketLeaseServer(socketPath: path, manager: manager) { _ in true }
        try server.start()
        defer { server.stop() }

        guard let first = openConnection(path) else { return XCTFail("could not connect") }
        let big = String(repeating: "a", count: 600)
        send(first, big)
        _ = readLine(first) // server rejects oversized input
        close(first)

        // Server must still serve new connections.
        guard let second = openConnection(path) else { return XCTFail("server died after oversized input") }
        send(second, "status")
        XCTAssertEqual(readLine(second), "OK inactive")
        close(second)
    }

    func testAbruptDisconnectReleasesLease() throws {
        let path = makeSocketPath()
        let setting = SocketFakeSetting(false)
        let manager = LeaseManager(setting: setting, store: SocketMemoryStore())
        let server = SocketLeaseServer(socketPath: path, manager: manager) { _ in true }
        try server.start()
        defer { server.stop() }

        guard let fd = openConnection(path) else { return XCTFail("could not connect") }
        send(fd, "enable")
        XCTAssertEqual(readLine(fd), "OK enabled")
        XCTAssertTrue(setting.value)
        close(fd) // abrupt close without disable

        XCTAssertTrue(waitUntil { setting.value == false }, "lease not released on abrupt disconnect")

        guard let again = openConnection(path) else { return XCTFail("could not reconnect") }
        send(again, "status")
        XCTAssertEqual(readLine(again), "OK inactive")
        close(again)
    }

    func testEnableRejectedWhenUninstallingFlagPresent() throws {
        let path = makeSocketPath()
        let flag = FileManager.default.temporaryDirectory
            .appendingPathComponent("tricup-flag-\(UUID().uuidString)").path
        FileManager.default.createFile(atPath: flag, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: flag) }

        let setting = SocketFakeSetting(false)
        let manager = LeaseManager(setting: setting, store: SocketMemoryStore())
        let server = SocketLeaseServer(
            socketPath: path,
            manager: manager,
            uninstallingFlagPath: flag
        ) { _ in true }
        try server.start()
        defer { server.stop() }

        guard let fd = openConnection(path) else { return XCTFail("could not connect") }
        send(fd, "enable")
        XCTAssertEqual(readLine(fd), "ERR uninstalling")
        XCTAssertFalse(setting.value)
        close(fd)
    }

    func testEnableRefusedWhileMaintenanceLockHeld() throws {
        let path = makeSocketPath()
        let lockDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tricup-lock-\(UUID().uuidString)").path
        XCTAssertEqual(mkdir(lockDir, 0o700), 0)
        defer { rmdir(lockDir) }

        let setting = SocketFakeSetting(false)
        let manager = LeaseManager(setting: setting, store: SocketMemoryStore())
        let server = SocketLeaseServer(
            socketPath: path,
            manager: manager,
            enableLockDirectory: lockDir,
            enableLockTimeout: 0.2
        ) { _ in true }
        try server.start()
        defer { server.stop() }

        guard let fd = openConnection(path) else { return XCTFail("could not connect") }
        send(fd, "enable")
        XCTAssertEqual(readLine(fd), "ERR busy")
        XCTAssertFalse(setting.value)
        close(fd)
    }

    func testIdleNonLeaseConnectionTimesOut() throws {
        let path = makeSocketPath()
        let setting = SocketFakeSetting(false)
        let manager = LeaseManager(setting: setting, store: SocketMemoryStore())
        let server = SocketLeaseServer(
            socketPath: path,
            manager: manager,
            idleTimeoutSeconds: 1
        ) { _ in true }
        try server.start()
        defer { server.stop() }

        guard let fd = openConnection(path) else { return XCTFail("could not connect") }
        Thread.sleep(forTimeInterval: 1.6)
        send(fd, "status")
        XCTAssertNotEqual(readLine(fd), "OK inactive", "idle non-lease connection should be closed")
        close(fd)
    }

    func testLeaseConnectionSurvivesIdleTimeout() throws {
        let path = makeSocketPath()
        let setting = SocketFakeSetting(false)
        let manager = LeaseManager(setting: setting, store: SocketMemoryStore())
        let server = SocketLeaseServer(
            socketPath: path,
            manager: manager,
            idleTimeoutSeconds: 1
        ) { _ in true }
        try server.start()
        defer { server.stop() }

        guard let fd = openConnection(path) else { return XCTFail("could not connect") }
        send(fd, "enable")
        XCTAssertEqual(readLine(fd), "OK enabled")
        Thread.sleep(forTimeInterval: 1.6) // longer than the idle timeout
        send(fd, "status")
        XCTAssertEqual(readLine(fd), "OK active", "lease connection must survive idle timeout")
        close(fd)
    }

    func testStaleEnableLockIsReclaimed() throws {
        let path = makeSocketPath()
        let lockDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tricup-lock-\(UUID().uuidString)").path
        XCTAssertEqual(mkdir(lockDir, 0o700), 0)
        // A PID that is not running: the server should reclaim the stale lock.
        try Data("999999".utf8).write(to: URL(fileURLWithPath: lockDir + "/pid"))
        defer { rmdir(lockDir) }

        let setting = SocketFakeSetting(false)
        let manager = LeaseManager(setting: setting, store: SocketMemoryStore())
        let server = SocketLeaseServer(
            socketPath: path,
            manager: manager,
            enableLockDirectory: lockDir,
            enableLockTimeout: 1.0
        ) { _ in true }
        try server.start()
        defer { server.stop() }

        guard let fd = openConnection(path) else { return XCTFail("could not connect") }
        send(fd, "enable")
        XCTAssertEqual(readLine(fd), "OK enabled", "stale lock should be reclaimed")
        XCTAssertTrue(setting.value)
        close(fd)
    }
}
