import Foundation
import TriCupCore

/// Installs and removes the privileged helper via a single administrator
/// authorization, using a generated shell script run through `do shell script`.
///
/// Security (see ADR-0001): fixed absolute destinations, argument values
/// shell-quoted, ownership/mode set explicitly, symlink targets removed before
/// writing, quarantine cleared only on the helper binary, and the script backs up
/// and restores an existing installation if an upgrade fails (so a failed install
/// never breaks a working helper or its lease). Gatekeeper is never disabled.
final class HelperInstaller {
    private let fileManager = FileManager.default

    /// Installed means the files exist AND the LaunchDaemon is actually loaded.
    var isInstalled: Bool {
        filesInstalled && launchDaemonLoaded()
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
            throw PowerError("Helper 安装后未就绪（文件 / LaunchDaemon / Socket 校验失败）")
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
            if filesInstalled && launchDaemonLoaded() && socketExists {
                return true
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return filesInstalled && launchDaemonLoaded() && socketExists
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

        // Redirect all script output to a log and record the exit status, so we
        // can surface the exact failing step/exit code/stderr on failure.
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
        BAK_DST="$DST.tricupbak"
        BAK_PLIST="$PLIST.tricupbak"
        HAD_OLD=0
        SUCCESS=0
        log() { /bin/echo "$*" >&2; }
        run() { log "+ $*"; "$@"; }
        cleanup_on_exit() {
            rc=$?
            trap - EXIT
            if [ "$SUCCESS" = "1" ]; then
                /bin/rm -f "$BAK_DST" "$BAK_PLIST"
                exit 0
            fi
            log "TRICUP_INSTALL_FAILED rc=$rc"
            /bin/rm -f "$DST" "$PLIST"
            if [ -f "$BAK_DST" ]; then /bin/mv "$BAK_DST" "$DST"; fi
            if [ -f "$BAK_PLIST" ]; then /bin/mv "$BAK_PLIST" "$PLIST"; fi
            if [ "$HAD_OLD" = "1" ] && [ -f "$PLIST" ]; then
                /bin/launchctl bootstrap system "$PLIST" 2>/dev/null || true
            fi
            exit $rc
        }
        trap cleanup_on_exit EXIT

        if [ -f "$DST" ]; then /bin/cp -p "$DST" "$BAK_DST"; fi
        if [ -f "$PLIST" ]; then /bin/cp -p "$PLIST" "$BAK_PLIST"; HAD_OLD=1; fi

        /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true

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
        log() { /bin/echo "$*" >&2; }
        /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
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
