import Foundation
#if canImport(Darwin)
import Darwin
#endif
import TriCupCore

/// App-side client for the privileged helper's Unix-domain socket.
///
/// The open connection *is* the lease: it is kept alive for as long as full mode
/// is active, and closing it (or the helper dying) restores the original power
/// setting on the helper side. Read-only status queries use a short-lived,
/// independent connection so they work even when no lease connection is open.
final class LidSleepClient: LidSleepControlling {
    private let socketPath: String
    private var fd: Int32 = -1
    private let ioTimeoutSeconds: Int = 3

    init(socketPath: String = HelperPaths.socketPath) {
        self.socketPath = socketPath
    }

    deinit {
        closeConnection()
    }

    func enable() throws {
        if fd >= 0 && !checkAlive() {
            closeConnection()
        }
        if fd >= 0, (try? leaseActive()) == true {
            return // already holds the lease on this connection
        }
        if fd < 0 {
            fd = try connectWithRetry()
        }
        do {
            let response = try sendCommand("enable", on: fd)
            guard response == "OK enabled" else {
                throw PowerError("helper enable failed: \(response)")
            }
        } catch {
            closeConnection()
            throw error
        }
    }

    func disable() throws {
        guard fd >= 0 else { return }
        defer { closeConnection() }
        let response = try sendCommand("disable", on: fd)
        guard response == "OK disabled" else {
            throw PowerError("helper disable failed: \(response)")
        }
    }

    func checkAlive() -> Bool {
        guard fd >= 0 else { return false }
        var buffer = [UInt8](repeating: 0, count: 1)
        let result = recv(fd, &buffer, 1, Int32(MSG_PEEK) | Int32(MSG_DONTWAIT))
        if result == 0 { return false }
        if result < 0 {
            let code = errno
            if code == EAGAIN || code == EWOULDBLOCK { return true }
            return false
        }
        return true
    }

    /// Queries the helper's lease state. Uses the existing lease connection when
    /// present, otherwise opens a short-lived read-only connection so an idle
    /// (empty) app is not mistaken for an unreachable helper.
    func leaseActive() throws -> Bool {
        if fd >= 0 {
            return try queryStatus(on: fd)
        }
        let temporary = try connectWithRetry()
        defer { close(temporary) }
        return try queryStatus(on: temporary)
    }

    private func queryStatus(on handle: Int32) throws -> Bool {
        let response = try sendCommand("status", on: handle)
        switch response {
        case "OK active": return true
        case "OK inactive": return false
        default: throw PowerError("unexpected status response: \(response)")
        }
    }

    /// Connects with a few short retries so that immediately after an install
    /// (helper still starting under launchd) the first enable can succeed.
    private func connectWithRetry() throws -> Int32 {
        var lastErrno: Int32 = 0
        for _ in 0..<20 {
            let handle = socket(AF_UNIX, SOCK_STREAM, 0)
            guard handle >= 0 else {
                lastErrno = errno
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            configure(handle)

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(socketPath.utf8)
            let capacity = MemoryLayout.size(ofValue: addr.sun_path)
            guard bytes.count < capacity else {
                close(handle)
                throw PowerError("socket path too long")
            }
            withUnsafeMutableBytes(of: &addr.sun_path) { raw in
                let base = raw.bindMemory(to: UInt8.self)
                for (index, value) in bytes.enumerated() {
                    base[index] = value
                }
                base[bytes.count] = 0
            }

            let length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let result = withUnsafePointer(to: &addr) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(handle, $0, length)
                }
            }
            if result == 0 {
                return handle
            }
            lastErrno = errno
            close(handle)
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw PowerError("connect() failed: errno \(lastErrno)")
    }

    /// Disables SIGPIPE and sets read/write timeouts so the main thread can never
    /// block forever on a wedged helper.
    private func configure(_ handle: Int32) {
        var on: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var timeout = timeval(tv_sec: ioTimeoutSeconds, tv_usec: 0)
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func sendCommand(_ command: String, on handle: Int32) throws -> String {
        guard handle >= 0 else {
            throw PowerError("helper not connected")
        }
        let data = Data((command + "\n").utf8)
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let written = write(handle, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                } else if written < 0 && errno == EINTR {
                    continue
                } else {
                    throw PowerError("write failed: errno \(errno)")
                }
            }
        }
        guard let line = readLine(on: handle) else {
            throw PowerError("helper gave no response")
        }
        return line
    }

    private func readLine(on handle: Int32) -> String? {
        var bytes = [UInt8]()
        var byte: UInt8 = 0
        while true {
            let count = read(handle, &byte, 1)
            if count == 0 {
                return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
            }
            if count < 0 {
                if errno == EINTR { continue }
                return nil
            }
            if byte == 0x0A {
                return String(decoding: bytes, as: UTF8.self)
            }
            if bytes.count >= 512 {
                return nil
            }
            bytes.append(byte)
        }
    }

    private func closeConnection() {
        if fd >= 0 {
            close(fd)
            fd = -1
        }
    }
}
