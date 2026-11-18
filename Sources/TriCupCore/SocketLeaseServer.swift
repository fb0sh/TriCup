import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A tiny line-based Unix-domain-socket server for the privileged helper.
///
/// Protocol (one command per line, one response line):
///   `enable`  -> `OK enabled` | `ERR <reason>`
///   `disable` -> `OK disabled` | `ERR <reason>`
///   `status`  -> `OK active` | `OK inactive`
///
/// The connection is the lease: closing it (normal quit, crash, kill -9)
/// releases any lease held by that connection and restores the original
/// `SleepDisabled` value through the injected `LeaseManager`.
public final class SocketLeaseServer {
    public typealias PeerValidator = (HelperPeerInfo) -> Bool

    private let socketPath: String
    private let manager: LeaseManager
    private let validatePeer: PeerValidator
    private let ownerUID: uid_t?
    private let ownerProvider: (() -> uid_t?)?
    private let mode: mode_t
    private let maxClients = 8
    /// Idle timeout for connections that do NOT hold a lease. A lease connection
    /// is set to no read timeout and may idle indefinitely.
    private let idleTimeoutSeconds: Int
    /// Optional cross-process lock directory shared with the root install/uninstall
    /// scripts to serialize enabling against maintenance.
    private let enableLockDirectory: String?
    private let enableLockTimeout: TimeInterval
    /// A lock directory without a live owner PID is only reclaimed once it is at
    /// least this old (avoids racing a just-created lock before its PID is written).
    private let lockStaleAge: TimeInterval = 5
    private let uninstallingFlagPath: String

    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var acceptThread: Thread?
    private var lastOwner: uid_t?
    private var activeClients = 0

    public init(
        socketPath: String = HelperPaths.socketPath,
        manager: LeaseManager,
        ownerUID: uid_t? = nil,
        ownerProvider: (() -> uid_t?)? = nil,
        mode: mode_t = 0o600,
        idleTimeoutSeconds: Int = 15,
        enableLockDirectory: String? = nil,
        enableLockTimeout: TimeInterval = 2.0,
        uninstallingFlagPath: String = HelperPaths.uninstallingFlagPath,
        validatePeer: @escaping PeerValidator
    ) {
        self.socketPath = socketPath
        self.manager = manager
        self.ownerUID = ownerUID
        self.ownerProvider = ownerProvider
        self.mode = mode
        self.idleTimeoutSeconds = idleTimeoutSeconds
        self.enableLockDirectory = enableLockDirectory
        self.enableLockTimeout = enableLockTimeout
        self.uninstallingFlagPath = uninstallingFlagPath
        self.validatePeer = validatePeer
    }

    public func start() throws {
        try bindAndListen()
        running = true
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "TriCupHelper.accept"
        acceptThread = thread
        thread.start()
        if ownerProvider != nil {
            let ownership = Thread { [weak self] in self?.ownershipLoop() }
            ownership.name = "TriCupHelper.ownership"
            ownership.start()
        }
    }

    public func stop() {
        running = false
        if listenFD >= 0 {
            close(listenFD)
            listenFD = -1
        }
        unlink(socketPath)
    }

    deinit {
        stop()
    }

    // MARK: - Socket setup

    private func bindAndListen() throws {
        unlink(socketPath)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw PowerError("socket() failed: errno \(errno)")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard pathBytes.count < capacity else {
            close(fd)
            throw PowerError("socket path too long")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let base = raw.bindMemory(to: UInt8.self)
            for (index, value) in pathBytes.enumerated() {
                base[index] = value
            }
            base[pathBytes.count] = 0
        }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bindResult == 0 else {
            let code = errno
            close(fd)
            throw PowerError("bind() failed: errno \(code)")
        }

        guard chmod(socketPath, mode) == 0 else {
            let code = errno
            close(fd)
            throw PowerError("chmod(socket) failed: errno \(code)")
        }
        if let owner = ownerProvider?() ?? ownerUID {
            guard chown(socketPath, owner, gid_t.max) == 0 else {
                let code = errno
                close(fd)
                throw PowerError("chown(socket) failed: errno \(code)")
            }
            lastOwner = owner
        }

        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            throw PowerError("listen() failed: errno \(code)")
        }

        listenFD = fd
    }

    // MARK: - Accept loop

    private func ownershipLoop() {
        while running {
            if let provider = ownerProvider, let uid = provider(), uid != lastOwner {
                chown(socketPath, uid, gid_t.max)
                chmod(socketPath, mode)
                lastOwner = uid
            }
            Thread.sleep(forTimeInterval: 2.0)
        }
    }

    private func acceptLoop() {
        while running {
            var clientAddress = sockaddr_un()
            var length = socklen_t(MemoryLayout<sockaddr_un>.size)
            let clientFD: Int32 = withUnsafeMutablePointer(to: &clientAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(listenFD, $0, &length) }
            }
            if clientFD < 0 {
                if !running { break }
                continue
            }

            lock.lock()
            let overloaded = activeClients >= maxClients
            if !overloaded { activeClients += 1 }
            lock.unlock()
            if overloaded {
                close(clientFD)
                continue
            }

            let thread = Thread { [weak self] in self?.handleClient(clientFD) }
            thread.name = "TriCupHelper.client"
            thread.start()
        }
    }

    // MARK: - Per-connection handling

    private func handleClient(_ fd: Int32) {
        var nosigpipe: Int32 = 1
        let noSigPipeOK = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size)) == 0
        let timeoutOK = setReadTimeout(fd, seconds: idleTimeoutSeconds)

        defer {
            lock.lock()
            activeClients -= 1
            lock.unlock()
            close(fd)
        }

        guard noSigPipeOK, timeoutOK else { return }

        guard let peer = peerInfo(fd: fd), validatePeer(peer) else {
            _ = writeLine(fd, "ERR unauthorized\n")
            return
        }

        var holdsLease = false
        defer {
            if holdsLease {
                lock.lock()
                try? manager.disable()
                lock.unlock()
            }
        }

        clientLoop: while let line = readLine(fd) {
            let command = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch command {
            case "enable":
                if maintenanceBlocked() {
                    if !writeLine(fd, "ERR uninstalling\n") { break clientLoop }
                    continue
                }
                lock.lock()
                guard acquireEnableLock() else {
                    lock.unlock()
                    if !writeLine(fd, "ERR busy\n") { break clientLoop }
                    continue
                }
                // Re-check after acquiring the lock: maintenance may have begun.
                if maintenanceBlocked() {
                    releaseEnableLock()
                    lock.unlock()
                    if !writeLine(fd, "ERR uninstalling\n") { break clientLoop }
                    continue
                }
                do {
                    try manager.enable()
                    holdsLease = true
                    releaseEnableLock()
                    lock.unlock()
                    // A lease connection must never inherit the idle timeout.
                    if !setReadTimeout(fd, seconds: 0) {
                        lock.lock()
                        try? manager.disable()
                        holdsLease = false
                        lock.unlock()
                        _ = writeLine(fd, "ERR timeout_policy\n")
                        break clientLoop
                    }
                    if !writeLine(fd, "OK enabled\n") { break clientLoop }
                } catch {
                    releaseEnableLock()
                    lock.unlock()
                    if !writeLine(fd, "ERR \(SocketLeaseServer.describe(error))\n") { break clientLoop }
                }
            case "disable":
                lock.lock()
                do {
                    try manager.disable()
                    holdsLease = false
                    lock.unlock()
                    _ = setReadTimeout(fd, seconds: idleTimeoutSeconds)
                    if !writeLine(fd, "OK disabled\n") { break clientLoop }
                } catch {
                    lock.unlock()
                    if !writeLine(fd, "ERR \(SocketLeaseServer.describe(error))\n") { break clientLoop }
                }
            case "status":
                lock.lock()
                let active = manager.isActive
                lock.unlock()
                if !writeLine(fd, active ? "OK active\n" : "OK inactive\n") { break clientLoop }
            default:
                if !writeLine(fd, "ERR unknown_command\n") { break clientLoop }
            }
        }
    }

    private func maintenanceBlocked() -> Bool {
        FileManager.default.fileExists(atPath: uninstallingFlagPath)
    }

    /// Cross-process mutual exclusion with the root install/uninstall scripts,
    /// implemented with an atomic `mkdir` lock directory plus a `pid` file. A
    /// lock whose owner died (e.g. SIGKILL) is reclaimed so a stale lock cannot
    /// permanently block full mode. Returns false on timeout.
    private func acquireEnableLock() -> Bool {
        guard let directory = enableLockDirectory else { return true }
        let parent = (directory as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        let pidPath = directory + "/pid"

        let deadline = Date().addingTimeInterval(enableLockTimeout)
        while Date() < deadline {
            if mkdir(directory, mode_t(0o700)) == 0 {
                let pidText = String(getpid())
                try? pidText.write(toFile: pidPath, atomically: true, encoding: .utf8)
                return true
            }
            if errno != EEXIST {
                return false
            }
            if reclaimStaleLock(directory: directory, pidPath: pidPath) {
                continue
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    /// Returns true if a stale lock was reclaimed (caller should retry mkdir).
    private func reclaimStaleLock(directory: String, pidPath: String) -> Bool {
        let fileManager = FileManager.default
        if let text = try? String(contentsOfFile: pidPath, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)),
           pid > 0 {
            if kill(pid, 0) == 0 || errno == EPERM {
                return false // owner still alive
            }
            try? fileManager.removeItem(atPath: pidPath)
            rmdir(directory)
            return true
        }
        // No readable PID: only reclaim after the directory is old enough.
        if let attributes = try? fileManager.attributesOfItem(atPath: directory),
           let modified = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) >= lockStaleAge {
            try? fileManager.removeItem(atPath: pidPath)
            rmdir(directory)
            return true
        }
        return false
    }

    private func releaseEnableLock() {
        guard let directory = enableLockDirectory else { return }
        try? FileManager.default.removeItem(atPath: directory + "/pid")
        rmdir(directory)
    }

    private func setReadTimeout(_ fd: Int32, seconds: Int) -> Bool {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        return setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0
    }

    private func peerInfo(fd: Int32) -> HelperPeerInfo? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else {
            return nil
        }

        var pid: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        // SOL_LOCAL == 0, LOCAL_PEERPID == 0x002 on Darwin.
        _ = getsockopt(fd, 0, 0x002, &pid, &pidLength)

        var executablePath: String?
        if pid > 0 {
            var buffer = [CChar](repeating: 0, count: 4096)
            let size = buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
                guard let base = pointer.baseAddress else { return 0 }
                return proc_pidpath(pid, UnsafeMutableRawPointer(base), UInt32(pointer.count))
            }
            if size > 0 {
                executablePath = String(cString: buffer)
            }
        }

        return HelperPeerInfo(uid: uid, pid: pid, executablePath: executablePath)
    }

    private static func describe(_ error: Error) -> String {
        if let leaseError = error as? LeaseError {
            return leaseError.description
        }
        return String(describing: error)
    }
}

// MARK: - Line IO helpers

private func readLine(_ fd: Int32) -> String? {
    var bytes = [UInt8]()
    var byte: UInt8 = 0
    while true {
        let readCount = read(fd, &byte, 1)
        if readCount == 0 {
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
        if readCount < 0 {
            if errno == EINTR { continue }
            // EAGAIN/EWOULDBLOCK => idle timeout: drop this (non-lease) connection.
            return nil
        }
        if byte == 0x0A {
            return String(decoding: bytes, as: UTF8.self)
        }
        if byte == 0x0D {
            continue
        }
        if bytes.count >= 512 {
            return nil
        }
        bytes.append(byte)
    }
}

@discardableResult
private func writeLine(_ fd: Int32, _ string: String) -> Bool {
    let data = Data(string.utf8)
    var ok = true
    var offset = 0
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        while offset < raw.count {
            let written = write(fd, base.advanced(by: offset), raw.count - offset)
            if written > 0 {
                offset += written
            } else if written < 0 && errno == EINTR {
                continue
            } else {
                ok = false
                break
            }
        }
    }
    return ok && offset == data.count
}
