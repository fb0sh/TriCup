import Foundation
import TriCupCore

/// `SleepDisabledSetting` backed by the system `/usr/bin/pmset` binary.
///
/// Always uses an absolute path and an argument array (never a shell), so no
/// client-supplied data can influence the invocation. Output is parsed strictly;
/// a missing or malformed value is an error, never silently `false`.
public final class PMSetSleepDisabledSetting: SleepDisabledSetting {
    private let pmsetPath = "/usr/bin/pmset"
    private let timeout: TimeInterval = 5

    public init() {}

    public func readSleepDisabled() throws -> Bool {
        let (status, output, errors) = try run(["-g"])
        guard status == 0 else {
            throw PowerError("pmset -g exited \(status): \(errors)")
        }
        return try SleepDisabledParser.parse(output)
    }

    public func writeSleepDisabled(_ disabled: Bool) throws {
        let (status, _, errors) = try run(["-a", "disablesleep", disabled ? "1" : "0"])
        guard status == 0 else {
            throw PowerError("pmset -a disablesleep exited \(status): \(errors)")
        }
    }

    private func run(_ arguments: [String]) throws -> (Int32, String, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pmsetPath)
        process.arguments = arguments
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw PowerError("failed to launch pmset: \(error)")
        }

        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw PowerError("pmset timed out after \(Int(timeout))s: \(arguments.joined(separator: " "))")
        }

        let output = String(decoding: outputPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: errorPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.terminationStatus, output, errors)
    }
}
