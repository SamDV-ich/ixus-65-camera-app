import Foundation
import AppKit
import Darwin

@main struct Integration {
    @MainActor static func main() async {
        do { try await run() } catch { print("FAIL:", error.localizedDescription); exit(1) }
    }
    @MainActor static func run() async throws {
        setbuf(stdout, nil)
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let service = CHDKCameraService(resources: resources)
        let reply = try await service.execute("status")
        guard reply.build?.platsub == "100a", reply.state?.mode == 1, reply.live == true else { fatalError("Unexpected camera state") }
        print("PASS: bundled service, JSON decoding, camera profile, state, live capability")
        let frame = URL(fileURLWithPath: "/private/tmp/ixus-app-integration.ppm")
        _ = try await service.execute("frame", output: frame)
        let image = try CameraModel.decodePPM(Data(contentsOf: frame))
        guard image.size.width == image.size.height * 4 / 3 else { fatalError("Wrong aspect ratio") }
        print("PASS: Live View through Swift service and native image decoder")
        do {
            _ = try await service.execute("flash", value: 99)
            fatalError("Invalid flash accepted")
        } catch { print("PASS: invalid parameter rejected:",error.localizedDescription) }
        do {
            _ = try CameraModel.decodePPM(Data("P6\n100 100\n255\nabc".utf8))
            fatalError("Truncated PPM accepted")
        } catch { print("PASS: truncated frame rejected") }
        if CommandLine.arguments.contains("--capture") {
            let output = ProcessInfo.processInfo.environment["IXUS_TEST_OUTPUT_DIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory.appendingPathComponent("ixus-capture-checks")
            let photo = output.appendingPathComponent("AppIntegration-" + UUID().uuidString + ".JPG")
            try FileManager.default.createDirectory(at: photo.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try await service.execute("capture", output: photo)
            guard NSImage(contentsOf: photo) != nil else { fatalError("Invalid JPEG") }
            print("PASS: single capture and JPEG download:",photo.path)
        }
        let final = try await service.execute("status")
        guard final.state?.mode == reply.state?.mode, final.state?.flash == reply.state?.flash,
              final.state?.aflock == reply.state?.aflock, final.state?.zoom == reply.state?.zoom else { fatalError("Settings changed") }
        print("PASS: mode, flash, AF lock and zoom preserved")
        await service.shutdown()
    }
}
