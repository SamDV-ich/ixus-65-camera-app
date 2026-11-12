import Foundation
import AppKit
import Darwin

@main struct DisplayIntegration {
    @MainActor static func wait(_ label: String, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(35)
        while !condition() {
            if Date() > deadline { throw CameraFailure(message: "Timeout: " + label) }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }
    @MainActor static func main() async {
        setbuf(stdout,nil)
        let service = CHDKCameraService(resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        let model = CameraModel(service: service)
        var initial: CameraState?
        var success = false
        do {
            _ = try await service.execute("status")
            _ = try await service.execute("play")
            let reply = try await service.execute("status")
            initial = reply.state
            guard reply.displaySupported == true, initial != nil else { throw CameraFailure(message: "No display support") }
            print("BASELINE:",initial!)
            model.update(reply); model.start()
            try await wait("startup") { !model.busy }
            model.startLive()
            try await wait("frames") { model.liveFrames >= 3 || model.error != nil }
            if let error = model.error { throw CameraFailure(message: error) }
            model.perform("display", value: 0)
            try await wait("LCD off command") { !model.busy }
            if let error = model.error { throw CameraFailure(message: error) }
            guard model.keepBacklightOff == true else { throw CameraFailure(message: "Off not acknowledged") }
            print("SCREEN_OFF: observe camera LCD now; collecting Live View for 15 seconds")
            let before = model.liveFrames
            var images = Set<Data>()
            for _ in 0..<30 {
                try await Task.sleep(nanoseconds: 500_000_000)
                if let error = model.error { throw CameraFailure(message: error) }
                if let image = model.preview?.tiffRepresentation { images.insert(image) }
            }
            guard model.liveFrames > before + 15, images.count > 1 else { throw CameraFailure(message: "Live image stopped or did not change") }
            print("PASS: LCD-off command, frames=\(model.liveFrames-before), distinct decoded images=\(images.count), polling remained active")
            model.perform("display", value: 1)
            try await wait("LCD on") { !model.busy }
            if let error = model.error { throw CameraFailure(message: error) }
            let position = initial!.zoom == 0 ? 1 : 0
            // Change the camera without updating the model: it must discover this by polling.
            _ = try await service.execute("zoom", value: position)
            try await wait("external zoom synchronized") { model.zoom == position }
            print("PASS: camera-side zoom change discovered by background polling while live")
            _ = try await service.execute("zoom", value: initial!.zoom)
            try await wait("zoom restored in UI") { model.zoom == initial!.zoom }
            let generation = await service.usbConnectionGeneration()
            guard generation == 1 else { throw CameraFailure(message: "Connection reopened") }
            model.stopLive()
            if !initial!.record { _ = try await service.execute("play") }
            print("PASS: zoom restored; one USB connection; no photographs taken")
            // Exit with screen commanded off: worker must send ON before disconnect.
            model.perform("display", value: 0)
            try await wait("off before shutdown") { !model.busy }
            if let error = model.error { throw CameraFailure(message: error) }
            success = true
        } catch { print("FAIL:",error.localizedDescription) }
        model.stopLive()
        if !success, let initial = initial {
            _ = try? await service.execute("display",value:1)
            _ = try? await service.execute("zoom",value:initial.zoom)
            if !initial.record { _ = try? await service.execute("play") }
        }
        await model.shutdown()
        print("SHUTDOWN: screen restore requested before disconnect; please confirm LCD is lit")
        if !success { exit(1) }
    }
}
