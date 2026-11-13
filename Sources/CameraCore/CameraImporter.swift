import Foundation
import Darwin

protocol CameraImporterControl: Sendable {
    func runningPIDs() -> [Int32]
    func stop(_ identifiers: [Int32]) throws
}
struct SystemCameraImporter: CameraImporterControl {
    func runningPIDs() -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-u", String(getuid()), "-x", "ptpcamerad"]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self).split(whereSeparator: { $0.isWhitespace }).compactMap { Int32($0) }.filter { $0 > 1 }
    }
    func stop(_ identifiers: [Int32]) throws {
        // Recheck the exact service name and current user's ownership immediately
        // before stopping only the processes observed for this failed connection.
        let current = Set(runningPIDs())
        for identifier in identifiers where current.contains(identifier) {
            if kill(identifier, SIGKILL) != 0 && errno != ESRCH {
                throw CameraFailure(message: "Не удалось освободить камеру от службы импорта macOS.")
            }
        }
    }
}
