import Foundation
import TriCupCore

/// `SleepDisabledSetting` backed by the system `/usr/bin/pmset` binary.
///
/// Always uses an absolute path and an argument array (never a shell), so no
/// client-supplied data can influence the invocation.
public final class PMSetSleepDisabledSetting: SleepDisabledSetting {
    private let pmsetPath = "/usr/bin/pmset"

    public init() {}

    public func readSleepDisabled() throws -> Bool {
        let (status, output) = try run(["-g"])
        guard status == 0 else {
            throw PowerError("pmset -g exited \(status)")
        }
        for line in output.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" {
                return parts[1] == "1"
            }
        }
        return false
    }

    public func writeSleepDisabled(_ disabled: Bool) throws {
        let (status, output) = try run(["-a", "disablesleep", disabled ? "1" : "0"])
        guard status == 0 else {
            throw PowerError("pmset -a disablesleep exited \(status): \(output)")
        }
    }

    private func run(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pmsetPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw PowerError("failed to launch pmset: \(error)")
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
