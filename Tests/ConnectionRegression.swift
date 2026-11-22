import Foundation
import Darwin

struct NoCameraImporter: CameraImporterControl {
    func runningPIDs() -> [Int32] { [] }
    func stop(_ identifiers: [Int32]) throws { throw CameraFailure(message: "Unexpected importer stop") }
}
@main struct ConnectionRegression {
    static func check(marker: String, expectedBusy: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ixus-protocol-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chdkptp"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("chdkptp/chdkptp")
        let script = """
        #!/bin/sh
        read -r request
        printf '%s\\n' '\(marker)'
        printf '%s\\n' 'IXUS_RESULT:{"ok":false,"error":"session unavailable","requestID":1,"connectionGeneration":0}'
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let service = CHDKCameraService(resources: root, importer: NoCameraImporter())
        do {
            _ = try await service.execute("status")
            throw CameraFailure(message: "Failure was incorrectly accepted")
        } catch {
            let busy = error.localizedDescription.contains("IXUS_BUSY:")
            guard busy == expectedBusy else { throw CameraFailure(message: "Wrong classification: " + error.localizedDescription) }
        }
        await service.shutdown()
    }
    static func checkDisconnect() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ixus-release-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("chdkptp"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("chdkptp/chdkptp")
        let script = """
        #!/bin/sh
        while IFS= read -r request; do
            if [ "$request" = QUIT ]; then exit 0; fi
            id=$(printf '%s' "$request" | /usr/bin/cut -f4)
            printf 'IXUS_RESULT:{"ok":true,"result":{},"requestID":%s,"connectionGeneration":1}\\n' "$id"
        done
        """
        try Data(script.utf8).write(to: helper)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let service = CHDKCameraService(resources: root, importer: NoCameraImporter())
        _ = try await service.execute("status")
        guard let first = await service.workerProcessIdentifier() else { throw CameraFailure(message: "Missing helper") }
        _ = try await service.execute("disconnect")
        let released = await service.workerProcessIdentifier()
        guard released == nil, kill(first, 0) == -1 else { throw CameraFailure(message: "Helper still owns session") }
        _ = try await service.execute("status")
        guard let second = await service.workerProcessIdentifier(), second != first else { throw CameraFailure(message: "Cannot reconnect") }
        await service.shutdown()
        print("PASS: disconnect exits helper and explicit reconnect opens a fresh session")
    }
    static func main() async {
        do {
            try await checkDisconnect()
            try await check(marker: "IXUS_USB_BUSY", expectedBusy: true)
            try await check(marker: "IXUS_USB_SESSION_FAILED:0x2ff", expectedBusy: false)
            print("PASS: helper busy marker survives protocol; session errors are not misreported as busy")
        } catch { print("FAIL:", error.localizedDescription); exit(1) }
    }
}
