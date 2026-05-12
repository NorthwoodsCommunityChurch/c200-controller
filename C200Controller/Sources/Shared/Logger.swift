import Foundation
import Darwin

/// Shared file logger. All app code should use appLog() instead of print().
/// On macOS:  tail -f ~/Library/Logs/c200_debug.log
/// On iOS:    view via Xcode Organizer or the app's Documents container

let logPath: String = {
    let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
    let dir = library.appendingPathComponent("Logs", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("c200_debug.log").path
}()

func appLog(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(timestamp)] \(message)\n"
    if let f = fopen(logPath, "a") {
        fputs(line, f)
        fclose(f)
    }
}
