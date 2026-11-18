import Foundation
#if canImport(Darwin)
import Darwin
#endif
import TriCupCore

/// Installs, upgrades and removes the privileged helper via a single
/// administrator authorization, using a generated shell script run through
/// `do shell script`.
///
/// Safety (see ADR-0001): fixed absolute destinations, shell-quoted arguments,
/// explicit root:wheel ownership/modes, symlink removal before writes. Upgrade
/// and uninstall acquire a shared `enable.lock` (atomic `mkdir`) so they wait for
/// any in-flight lease enable, then set an `uninstalling` flag that makes the
/// helper refuse new leases. They refuse while a lease record exists and never
/// delete state while a recovery record may be needed. A failed `launchctl
/// bootout` or install failure keeps/restores the previous helper and state.
final class HelperInstaller {
    enum HelperStatus: Equatable {
        case notInstalled
        case installedNotRunning
        case recovering
        case ready
    }

    private let fileManager = FileManager.default

    var isInstalled: Bool {
        filesInstalled && launchDaemonLoaded()
    }

    var status: HelperStatus {
        guard filesInstalled else { return .notInstalled }
        guard launchDaemonLoaded() else { return .installedNotRunning }
        return socketExists ? .ready : .recovering
    }

    private var filesInstalled: Bool {
        fileManager.fileExists(atPath: HelperPaths.helperBinaryPath)
            && fileManager.fileExists(atPath: HelperPaths.launchDaemonPlistPath)
    }

    private var socketExists: Bool {
        fileManager.fileExists(atPath: HelperPaths.socketPath)
    }

    private var bundledHelperPath: String? {
        let path = Bundle.main.bundleURL
            .appendingPathComponent("Contents/MacOS/TriCupHelper").path
        return fileManager.fileExists(atPath: path) ? path : nil
    }

    func install() throws {
        guard let source = bundledHelperPath else {
            throw PowerError("应用包内缺少 TriCupHelper")
        }
        try runPrivileged(makeInstallScript(helperSource: source))
        guard waitUntilReady() else {
            throw PowerError("Helper 安装后未就绪（文件 / LaunchDaemon / Socket / 协议响应校验失败）")
        }
    }

    func uninstall() throws {
        try runPrivileged(makeUninstallScript())
    }

    // MARK: - Readiness

    private func launchDaemonLoaded() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(HelperPaths.launchDaemonLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func waitUntilReady(timeout: TimeInterval = 8.0) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if filesInstalled && launchDaemonLoaded() && socketExists && helperResponds() {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return filesInstalled && launchDaemonLoaded() && socketExists && helperResponds()
    }

    private func helperResponds() -> Bool {
        let handle = socket(AF_UNIX, SOCK_STREAM, 0)
        guard handle >= 0 else { return false }
        defer { close(handle) }

        var noSigPipe: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(handle, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(handle, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(HelperPaths.socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else { return false }
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
        guard result == 0 else { return false }

        let request = Data("status\n".utf8)
        var offset = 0
        request.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let written = write(handle, base.advanced(by: offset), raw.count - offset)
                if written <= 0 { return }
                offset += written
            }
        }

        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(handle, &buffer, buffer.count)
        guard count > 0 else { return false }
        let response = String(decoding: buffer[0..<count], as: UTF8.self)
        return response.hasPrefix("OK ")
    }

    // MARK: - Script execution

    private func runPrivileged(_ script: String) throws {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("tricup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("run.sh")
        let logURL = directory.appendingPathComponent("install.log")
        let statusURL = directory.appendingPathComponent("status")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try? fileManager.removeItem(at: logURL)
        try? fileManager.removeItem(at: statusURL)

        let command = "/bin/sh \(shellQuote(scriptURL.path))"
            + " > \(shellQuote(logURL.path)) 2>&1"
            + "; /usr/bin/printf '%s' $? > \(shellQuote(statusURL.path))"
        let appleSource = "do shell script \"\(appleEscape(command))\" with administrator privileges"
        guard let appleScript = NSAppleScript(source: appleSource) else {
            throw PowerError("无法创建安装脚本")
        }
        var errorInfo: NSDictionary?
        _ = appleScript.executeAndReturnError(&errorInfo)

        let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        guard let statusText = try? String(contentsOf: statusURL, encoding: .utf8),
              let code = Int(statusText.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            let reason = errorInfo.map { "\($0)" } ?? "未产生退出状态"
            throw PowerError("安装/卸载未执行完成（可能被取消）：\(reason)")
        }
        if code != 0 {
            throw PowerError("安装/卸载脚本失败（exit \(code)）：\n\(Self.tail(log))")
        }
    }

    private static func tail(_ text: String, limit: Int = 2000) -> String {
        if text.count <= limit { return text }
        return String(text.suffix(limit))
    }

    // MARK: - Script generation

    private func makeInstallScript(helperSource: String) -> String {
        let plistBody = shellQuote(daemonPlistXML())
        return """
        #!/bin/sh
        set -eu
        LABEL=\(shellQuote(HelperPaths.launchDaemonLabel))
        DST=\(shellQuote(HelperPaths.helperBinaryPath))
        PLIST=\(shellQuote(HelperPaths.launchDaemonPlistPath))
        STATEDIR=\(shellQuote(HelperPaths.helperDirectory))
        SOURCE=\(shellQuote(helperSource))
        LEASE="$STATEDIR/lease.json"
        FLAG="$STATEDIR/uninstalling"
        LOCKDIR="$STATEDIR/enable.lock"
        LOCKPID="$LOCKDIR/pid"
        BAK_DST="$DST.tricupbak"
        BAK_PLIST="$PLIST.tricupbak"
        HAD_OLD=0
        SUCCESS=0
        STARTED=0
        LOCKED=0
        log() { /bin/echo "$*" >&2; }
        run() { log "+ $*"; "$@"; }
        cleanup_on_exit() {
            rc=$?
            trap - EXIT
            if [ "$LOCKED" = "1" ]; then
                /bin/rm -f "$FLAG"
                /bin/rm -f "$LOCKPID"
                /bin/rmdir "$LOCKDIR" 2>/dev/null || true
            fi
            if [ "$SUCCESS" = "1" ]; then
                /bin/rm -f "$BAK_DST" "$BAK_PLIST"
                exit 0
            fi
            log "TRICUP_INSTALL_FAILED rc=$rc"
            if [ "$STARTED" = "1" ]; then
                /bin/rm -f "$DST" "$PLIST"
                if [ -f "$BAK_DST" ]; then /bin/mv "$BAK_DST" "$DST"; fi
                if [ -f "$BAK_PLIST" ]; then /bin/mv "$BAK_PLIST" "$PLIST"; fi
                if [ "$HAD_OLD" = "1" ] && [ -f "$PLIST" ]; then
                    /bin/launchctl bootstrap system "$PLIST" 2>/dev/null || true
                fi
            fi
            exit $rc
        }

        /bin/mkdir -p "$STATEDIR"
        /bin/chmod 0700 "$STATEDIR" 2>/dev/null || true
        trap cleanup_on_exit EXIT

        acquire_lock() {
            n=0
            while ! /bin/mkdir "$LOCKDIR" 2>/dev/null; do
                if [ -f "$LOCKPID" ]; then
                    lpid=$(/bin/cat "$LOCKPID" 2>/dev/null || true)
                    if [ -n "$lpid" ] && ! /bin/kill -0 "$lpid" 2>/dev/null; then
                        /bin/rm -f "$LOCKPID"
                        /bin/rmdir "$LOCKDIR" 2>/dev/null || true
                        continue
                    fi
                else
                    now=$(/bin/date +%s)
                    mt=$(/usr/bin/stat -f %m "$LOCKDIR" 2>/dev/null || /bin/echo "$now")
                    if [ $((now - mt)) -ge 5 ]; then
                        /bin/rmdir "$LOCKDIR" 2>/dev/null || true
                        continue
                    fi
                fi
                n=$((n+1))
                if [ "$n" -ge 50 ]; then log "TRICUP_INSTALL_REFUSED: enable lock timeout"; return 1; fi
                /bin/sleep 0.1
            done
            /usr/bin/printf '%s' "$$" > "$LOCKPID"
            return 0
        }
        if ! acquire_lock; then exit 5; fi
        LOCKED=1
        (umask 077; : > "$FLAG")

        if [ -f "$LEASE" ]; then
            log "TRICUP_INSTALL_REFUSED: residual lease record present"
            exit 4
        fi

        if [ -f "$DST" ]; then /bin/cp -p "$DST" "$BAK_DST"; fi
        if [ -f "$PLIST" ]; then /bin/cp -p "$PLIST" "$BAK_PLIST"; HAD_OLD=1; fi
        STARTED=1

        if [ -f "$LEASE" ]; then
            log "TRICUP_INSTALL_REFUSED: lease appeared during upgrade"
            exit 4
        fi

        if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
            run /bin/launchctl bootout "system/$LABEL"
        fi

        run /bin/mkdir -p /Library/PrivilegedHelperTools
        if [ -L "$DST" ]; then /bin/rm -f "$DST"; fi
        run /bin/cp "$SOURCE" "$DST"
        /usr/bin/xattr -c "$DST" 2>/dev/null || true
        run /usr/sbin/chown root:wheel "$DST"
        run /bin/chmod 0755 "$DST"

        run /bin/mkdir -p "$STATEDIR"
        run /usr/sbin/chown root:wheel "$STATEDIR"
        run /bin/chmod 0700 "$STATEDIR"

        if [ -L "$PLIST" ]; then /bin/rm -f "$PLIST"; fi
        /usr/bin/printf '%s' \(plistBody) > "$PLIST"
        run /usr/sbin/chown root:wheel "$PLIST"
        run /bin/chmod 0644 "$PLIST"

        run /bin/launchctl bootstrap system "$PLIST"
        /bin/launchctl enable "system/$LABEL" 2>/dev/null || true
        if ! /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
            log "launchctl print failed after bootstrap"
            exit 1
        fi
        SUCCESS=1
        """
    }

    private func makeUninstallScript() -> String {
        return """
        #!/bin/sh
        set -eu
        LABEL=\(shellQuote(HelperPaths.launchDaemonLabel))
        PLIST=\(shellQuote(HelperPaths.launchDaemonPlistPath))
        DST=\(shellQuote(HelperPaths.helperBinaryPath))
        STATEDIR=\(shellQuote(HelperPaths.helperDirectory))
        LEASE="$STATEDIR/lease.json"
        FLAG="$STATEDIR/uninstalling"
        LOCKDIR="$STATEDIR/enable.lock"
        LOCKPID="$LOCKDIR/pid"
        LOCKED=0
        log() { /bin/echo "$*" >&2; }
        cleanup_on_exit() {
            rc=$?
            trap - EXIT
            if [ "$LOCKED" = "1" ]; then
                /bin/rm -f "$FLAG"
                /bin/rm -f "$LOCKPID"
                /bin/rmdir "$LOCKDIR" 2>/dev/null || true
            fi
            exit $rc
        }

        /bin/mkdir -p "$STATEDIR"
        /bin/chmod 0700 "$STATEDIR" 2>/dev/null || true
        trap cleanup_on_exit EXIT

        acquire_lock() {
            n=0
            while ! /bin/mkdir "$LOCKDIR" 2>/dev/null; do
                if [ -f "$LOCKPID" ]; then
                    lpid=$(/bin/cat "$LOCKPID" 2>/dev/null || true)
                    if [ -n "$lpid" ] && ! /bin/kill -0 "$lpid" 2>/dev/null; then
                        /bin/rm -f "$LOCKPID"
                        /bin/rmdir "$LOCKDIR" 2>/dev/null || true
                        continue
                    fi
                else
                    now=$(/bin/date +%s)
                    mt=$(/usr/bin/stat -f %m "$LOCKDIR" 2>/dev/null || /bin/echo "$now")
                    if [ $((now - mt)) -ge 5 ]; then
                        /bin/rmdir "$LOCKDIR" 2>/dev/null || true
                        continue
                    fi
                fi
                n=$((n+1))
                if [ "$n" -ge 50 ]; then log "TRICUP_UNINSTALL_REFUSED: enable lock timeout"; return 1; fi
                /bin/sleep 0.1
            done
            /usr/bin/printf '%s' "$$" > "$LOCKPID"
            return 0
        }
        if ! acquire_lock; then exit 5; fi
        LOCKED=1
        (umask 077; : > "$FLAG")

        if [ -f "$LEASE" ]; then
            log "TRICUP_UNINSTALL_REFUSED: residual lease record present; keeping helper and state"
            exit 3
        fi

        if /bin/launchctl print "system/$LABEL" >/dev/null 2>&1; then
            if ! /bin/launchctl bootout "system/$LABEL"; then
                log "TRICUP_UNINSTALL_REFUSED: launchctl bootout failed; keeping files"
                exit 6
            fi
        fi

        /bin/rm -f "$PLIST"
        /bin/rm -f "$DST"
        /bin/rm -rf "$STATEDIR"
        log "uninstalled"
        """
    }

    private func daemonPlistXML() -> String {
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(HelperPaths.launchDaemonLabel)</string>
            <key>ProgramArguments</key>
            <array><string>\(HelperPaths.helperBinaryPath)</string></array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><true/>
            <key>StandardOutPath</key><string>\(HelperPaths.helperDirectory)/helper.log</string>
            <key>StandardErrorPath</key><string>\(HelperPaths.helperDirectory)/helper.log</string>
        </dict>
        </plist>
        """
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func appleEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
