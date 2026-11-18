import Foundation
#if canImport(Darwin)
import Darwin
#endif
import TriCupCore

/// App-side reader for the real system `SleepDisabled` value via `pmset -g`
/// (read-only; never modifies power settings).
final class PMSetSleepStateReader: SleepStateReading {
    private let pmsetPath = "/usr/bin/pmset"

    func readSleepDisabled() throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pmsetPath)
        process.arguments = ["-g"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw PowerError("pmset -g exited \(process.terminationStatus)")
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return try PMSetSleepStateReader.parse(text)
    }

    /// Strictly parses `pmset -g`; missing or malformed values are errors, not
    /// silently treated as false.
    static func parse(_ text: String) throws -> Bool {
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if parts.count >= 2, parts[0] == "SleepDisabled" {
                switch parts[1] {
                case "1": return true
                case "0": return false
                default: throw PowerError("invalid SleepDisabled value: \(parts[1])")
                }
            }
        }
        throw PowerError("pmset -g did not report SleepDisabled")
    }
}
