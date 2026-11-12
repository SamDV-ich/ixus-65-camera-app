import Foundation
import AppKit
import Darwin

@main struct PersistentIntegration {
    @MainActor static func waitFor(_ label: String, _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(35)
        while !condition() {
            guard Date() < deadline else { throw CameraFailure(message: "Timeout: " + label) }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
    }
    @MainActor static func main() async {
        setbuf(stdout, nil)
        let service = CHDKCameraService(resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        var baseline: CameraState?
        var model: CameraModel?
        var succeeded = false
        do {
            let reply = try await service.execute("status")
            guard let initial = reply.state else { throw CameraFailure(message: "No baseline") }
            baseline = initial
            print("BASELINE:",initial)
            let pid = await service.workerProcessIdentifier()
            let connection = await service.usbConnectionGeneration()
            let vm = CameraModel(service: service); model = vm; vm.update(reply)
            vm.startLive()
            try await waitFor("first frames") { vm.liveFrames >= 5 || vm.error != nil }
            if let error = vm.error { throw CameraFailure(message: error) }
            print("PASS: continuous live frames:",vm.liveFrames)
            let startFrames = vm.liveFrames
            vm.perform("flash", value: initial.flash == 2 ? 0 : 2)
            try await waitFor("flash during live") { !vm.busy && (vm.liveFrames > startFrames + 3 || vm.error != nil) }
            if let error = vm.error { throw CameraFailure(message: error) }
            print("PASS: flash applied while preview active; frames resumed:",vm.liveFrames)
            vm.perform("flash", value: initial.flash)
            try await waitFor("restore flash") { !vm.busy }
            let beforeZoom = vm.liveFrames
            vm.perform("zoom", value: initial.zoom == 0 ? 1 : 0)
            try await waitFor("zoom during live") { !vm.busy && (vm.liveFrames > beforeZoom + 3 || vm.error != nil) }
            if let error = vm.error { throw CameraFailure(message: error) }
            print("PASS: zoom applied while preview active; frames resumed:",vm.liveFrames)
            vm.perform("zoom", value: initial.zoom)
            try await waitFor("restore zoom") { !vm.busy }
            let endTime = Date().addingTimeInterval(15)
            while Date() < endTime && vm.error == nil { try await Task.sleep(nanoseconds: 200_000_000) }
            if let error = vm.error { throw CameraFailure(message: error) }
            guard vm.live, vm.liveFrames > 30 else { throw CameraFailure(message: "Preview stopped") }
            vm.stopLive()
            if !initial.record { _ = try await service.execute("play") }
            let final = try await service.execute("status")
            print("FINAL:",String(describing:final.state))
            guard final.state?.record == initial.record, final.state?.flash == initial.flash, final.state?.zoom == initial.zoom, final.state?.mode == initial.mode, final.state?.aflock == initial.aflock else { throw CameraFailure(message: "Settings changed") }
            let finalPID = await service.workerProcessIdentifier()
            let finalConnection = await service.usbConnectionGeneration()
            guard pid == finalPID, connection == finalConnection else { throw CameraFailure(message: "Session reopened") }
            print("PASS: frames=\(vm.liveFrames), worker PID=\(pid ?? -1), USB connection generation=\(connection ?? -1), unchanged")
            print("PASS: mode, flash, zoom, AF lock preserved; no photograph taken")
            succeeded = true
        } catch { print("FAIL:",error.localizedDescription) }
        model?.stopLive()
        if let initial = baseline {
            do {
                if !succeeded {
                    _ = try await service.execute("record")
                    _ = try await service.execute("flash",value: initial.flash)
                    _ = try await service.execute("zoom",value: initial.zoom)
                }
                if !initial.record && !succeeded { _ = try await service.execute("play") }
            } catch { print("RESTORE FAILED:",error.localizedDescription); succeeded = false }
        }
        await service.shutdown()
        if !succeeded { exit(1) }
        print("PASS: graceful shutdown releases USB session")
    }
}
