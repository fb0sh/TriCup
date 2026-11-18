import Foundation
import TriCupCore

/// Installs and removes the privileged helper via a single administrator
/// authorization, using a generated shell script run through `do shell script`.
///
/// Security (see ADR-0001): fixed absolute destinations, argument values
/// shell-quoted, ownership/mode set explicitly, symlink targets removed before
/// writing, quarantine cleared only on the helper binary, and the script cleans
/// up partial artifacts if it fails. Gatekeeper is never disabled.
final class HelperInstaller {
    private let fileManager = FileManager.default

    var isInstalled: Bool {
        fileManager.fileExists(atPath: HelperPaths.helperBinaryPath)
            && fileManager.fileExists(atPath: HelperPaths.launchDaemonPlistPath)
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
    }

    func uninstall() throws {
        try runPrivileged(makeUninstallScript())
    }

    // MARK: - Script execution

    private func runPrivileged(_ script: String) throws {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("tricup-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let scriptURL = directory.appendingPathComponent("run.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let source = "do shell script \"/bin/sh \" & quoted form of \"\(appleEscape(scriptURL.path))\" with administrator privileges"
        guard let appleScript = NSAppleScript(source: source) else {
            throw PowerError("无法创建安装脚本")
        }
        var errorInfo: NSDictionary?
        _ = appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo = errorInfo {
            throw PowerError("安装/卸载被取消或失败：\(errorInfo)")
        }
    }

    // MARK: - Script generation

    private func makeInstallScript(helperSource: String) -> String {
        let label = HelperPaths.launchDaemonLabel
        let plistBody = shellQuote(daemonPlistXML())
        return """
        #!/bin/sh
        set -eu
        LABEL=\(shellQuote(label))
        DST=\(shellQuote(HelperPaths.helperBinaryPath))
        PLIST=\(shellQuote(HelperPaths.launchDaemonPlistPath))
        STATEDIR=\(shellQuote(HelperPaths.helperDirectory))
        SOURCE=\(shellQuote(helperSource))
        CLEANUP=1
        cleanup() { if [ "${CLEANUP:-0}" = "1" ]; then /bin/rm -f "$PLIST" "$DST"; fi }
        trap cleanup EXIT

        /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true

        /bin/mkdir -p /Library/PrivilegedHelperTools
        if [ -L "$DST" ]; then /bin/rm -f "$DST"; fi
        /bin/cp "$SOURCE" "$DST"
        /usr/bin/xattr -c "$DST" 2>/dev/null || true
        /usr/sbin/chown root:wheel "$DST"
        /bin/chmod 0755 "$DST"

        /bin/mkdir -p "$STATEDIR"
        /usr/sbin/chown root:wheel "$STATEDIR"
        /bin/chmod 0700 "$STATEDIR"

        if [ -L "$PLIST" ]; then /bin/rm -f "$PLIST"; fi
        /bin/printf '%s' \(plistBody) > "$PLIST"
        /usr/sbin/chown root:wheel "$PLIST"
        /bin/chmod 0644 "$PLIST"

        /bin/launchctl bootstrap system "$PLIST"
        /bin/launchctl enable "system/$LABEL" 2>/dev/null || true
        CLEANUP=0
        """
    }

    private func makeUninstallScript() -> String {
        return """
        #!/bin/sh
        set -u
        LABEL=\(shellQuote(HelperPaths.launchDaemonLabel))
        PLIST=\(shellQuote(HelperPaths.launchDaemonPlistPath))
        DST=\(shellQuote(HelperPaths.helperBinaryPath))
        STATEDIR=\(shellQuote(HelperPaths.helperDirectory))

        /bin/launchctl bootout "system/$LABEL" 2>/dev/null || true
        /bin/rm -f "$PLIST"
        /bin/rm -f "$DST"
        /bin/rm -rf "$STATEDIR"
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
