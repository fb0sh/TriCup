import AppKit
#if canImport(Darwin)
import Darwin
#endif

/// Validates that the packaged app bundle can load its resources from
/// `Bundle.main` (not from a SwiftPM build directory). Used by CI as an
/// independent-path smoke test.
private func runResourceSelfTest() -> Bool {
    var ok = true
    let resources: [(String, String)] = [
        ("empty", "png"),
        ("half", "png"),
        ("full", "png"),
        ("AppIcon", "icns")
    ]
    for (name, ext) in resources {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext),
              FileManager.default.fileExists(atPath: url.path) else {
            print("MISSING \(name).\(ext)")
            ok = false
            continue
        }
        if ext == "png", NSImage(contentsOf: url) == nil {
            print("UNREADABLE \(name).\(ext)")
            ok = false
            continue
        }
        print("OK \(name).\(ext): \(url.path)")
    }
    print("Bundle: \(Bundle.main.bundlePath)")
    return ok
}

if CommandLine.arguments.contains("--self-test") {
    exit(runResourceSelfTest() ? 0 : 1)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
