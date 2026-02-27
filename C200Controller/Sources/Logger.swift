import Foundation

/// Shared file logger. All app code should use appLog() instead of print().
/// View log in Terminal:  tail -f ~/Library/Logs/c200_debug.log
import Darwin

let logPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/c200_debug.log").path

func appLog(_ message: String) {
    let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
    let line = "[\(timestamp)] \(message)\n"
    // Use C fopen/fwrite - bypasses all Swift/ObjC overhead
    if let f = fopen(logPath, "a") {
        fputs(line, f)
        fclose(f)
    }
}
