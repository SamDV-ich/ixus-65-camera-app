import Foundation
import Darwin

final class FakeCameraImporter: CameraImporterControl, @unchecked Sendable {
    let root: URL
    let present: Bool
    let releaseWorks: Bool
    private(set) var stops = 0
    init(root: URL, present: Bool, releaseWorks: Bool) { self.root = root; self.present = present; self.releaseWorks = releaseWorks }
    func runningPIDs() -> [Int32] { present ? [123] : [] }
    func stop(_ identifiers: [Int32]) throws {
        guard identifiers == [123] else { throw CameraFailure(message: "Wrong importer identity") }
        stops += 1
        if releaseWorks { try Data().write(to: root.appendingPathComponent("ready")) }
    }
}
@main struct AutomaticConnectionRegression {
    static func check(marker: String, importerPresent: Bool = true, releaseWorks: Bool = true, shouldRecover: Bool, shouldStop: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ixus-auto-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chdkptp"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("chdkptp/chdkptp")
        let script = """
        #!/bin/sh
        while read -r request; do
        requestID=$(printf '%s\n' "$request" | /usr/bin/awk -F '\t' '{print $4}')
        if [ -f '\(root.path)/ready' ]; then
            printf 'IXUS_RESULT:{"ok":true,"result":{},"requestID":%s,"connectionGeneration":1}\n' "$requestID"
        elif [ -f '\(root.path)/absent' ]; then
            printf 'IXUS_RESULT:{"ok":false,"error":"IXUS_ABSENT: absent","requestID":%s,"connectionGeneration":0}\n' "$requestID"
        else
            printf '%s\n' '\(marker)'
            printf 'IXUS_RESULT:{"ok":false,"error":"session unavailable","requestID":%s,"connectionGeneration":0}\n' "$requestID"
        fi
        done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let importer = FakeCameraImporter(root: root, present: importerPresent, releaseWorks: releaseWorks)
        let service = CHDKCameraService(resources: root, importer: importer)
        var recovered = false
        do { _ = try await service.execute("status"); recovered = true } catch {}
        guard recovered == shouldRecover, importer.stops == (shouldStop ? 1 : 0) else {
            await service.shutdown(); throw CameraFailure(message: "Wrong auto recovery for " + marker)
        }
        if shouldStop && !releaseWorks {
            do { _ = try await service.execute("status") } catch {}
            guard importer.stops == 1 else { throw CameraFailure(message: "Repeated importer termination in the same failure episode") }
            try Data().write(to: root.appendingPathComponent("absent"))
            do { _ = try await service.execute("status") } catch {}
            try FileManager.default.removeItem(at: root.appendingPathComponent("absent"))
            do { _ = try await service.execute("status") } catch {}
            guard importer.stops == 2 else { throw CameraFailure(message: "Unplug did not reset bounded recovery") }
        }
        await service.shutdown()
    }
    static func main() async {
        do {
            try await check(marker: "IXUS_USB_BUSY", shouldRecover: true, shouldStop: true)
            try await check(marker: "IXUS_USB_UNAVAILABLE", shouldRecover: true, shouldStop: true)
            try await check(marker: "IXUS_USB_SESSION_FAILED:0x2ff", shouldRecover: false, shouldStop: false)
            try await check(marker: "I/O error", shouldRecover: false, shouldStop: false)
            try await check(marker: "IXUS_USB_BUSY", importerPresent: false, shouldRecover: false, shouldStop: false)
            try await check(marker: "IXUS_USB_BUSY", releaseWorks: false, shouldRecover: false, shouldStop: true)
            print("PASS: automatic USB claim recovery, generic-error isolation, missing importer, bounded stopping and unplug reset; no real service or camera used")
        } catch { print("FAIL:", error.localizedDescription); exit(1) }
    }
}
