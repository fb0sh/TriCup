import Foundation
#if canImport(Darwin)
import Darwin
#endif
import TriCupCore

/// App-side reader for the real system `SleepDisabled` value via `pmset -g`
/// (read-only; never modifies power settings). Parsing is strict and shared with
/// the helper via `SleepDisabledParser`.
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
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw PowerError("pmset -g exited \(process.terminationStatus): \(message)")
        }
        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return try SleepDisabledParser.parse(text)
    }
}
