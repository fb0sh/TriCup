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
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var running = false
    private var acceptThread: Thread?
    private var lastOwner: uid_t?

    public init(
        socketPath: String = HelperPaths.socketPath,
        manager: LeaseManager,
        ownerUID: uid_t? = nil,
        ownerProvider: (() -> uid_t?)? = nil,
        mode: mode_t = 0o600,
        validatePeer: @escaping PeerValidator
    ) {
        self.socketPath = socketPath
        self.manager = manager
        self.ownerUID = ownerUID
        self.ownerProvider = ownerProvider
        self.mode = mode
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

        chmod(socketPath, mode)
        if let owner = ownerProvider?() ?? ownerUID {
            chown(socketPath, owner, gid_t.max)
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

    /// Keeps the socket owned by the current console user, so that after a
    /// reboot (where the daemon starts as root before login) the logged-in user
    /// can still connect. The socket stays mode 0600.
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
            let thread = Thread { [weak self] in self?.handleClient(clientFD) }
            thread.name = "TriCupHelper.client"
            thread.start()
        }
    }

    // MARK: - Per-connection handling

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }

        guard let peer = peerInfo(fd: fd), validatePeer(peer) else {
            writeLine(fd, "ERR unauthorized\n")
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

        while let line = readLine(fd) {
            let command = line.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch command {
            case "enable":
                lock.lock()
                do {
                    try manager.enable()
                    holdsLease = true
                    lock.unlock()
                    writeLine(fd, "OK enabled\n")
                } catch {
                    lock.unlock()
                    writeLine(fd, "ERR \(SocketLeaseServer.describe(error))\n")
                }
            case "disable":
                lock.lock()
                do {
                    try manager.disable()
                    holdsLease = false
                    lock.unlock()
                    writeLine(fd, "OK disabled\n")
                } catch {
                    lock.unlock()
                    writeLine(fd, "ERR \(SocketLeaseServer.describe(error))\n")
                }
            case "status":
                lock.lock()
                let active = manager.isActive
                lock.unlock()
                writeLine(fd, active ? "OK active\n" : "OK inactive\n")
            default:
                writeLine(fd, "ERR unknown_command\n")
            }
        }
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

private func writeLine(_ fd: Int32, _ string: String) {
    let data = Data(string.utf8)
    data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let written = write(fd, base.advanced(by: offset), raw.count - offset)
            if written <= 0 { break }
            offset += written
        }
    }
}
