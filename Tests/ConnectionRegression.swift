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
    static func main() async {
        do {
            try await check(marker: "IXUS_USB_BUSY", expectedBusy: true)
            try await check(marker: "IXUS_USB_SESSION_FAILED:0x2ff", expectedBusy: false)
            print("PASS: helper busy marker survives protocol; session errors are not misreported as busy")
        } catch { print("FAIL:", error.localizedDescription); exit(1) }
    }
}
