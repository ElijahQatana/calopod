import Foundation

enum Pasteboard {
    /// Hands text to `pbcopy`. False when it is missing or fails.
    static func copy(_ text: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pbcopy")
        let input = Pipe()
        process.standardInput = input
        do {
            try process.run()
        } catch {
            return false
        }
        input.fileHandleForWriting.write(Data(text.utf8))
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
