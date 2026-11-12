import Foundation
import ImageIO
import UniformTypeIdentifiers

struct SaveSettings: Codable, Sendable {
    var destination = 0 // 0: camera and Mac, 1: camera, 2: Mac after verified download
    var format = "jpeg"
    var keepJPEG = true
    var naming = "datetime"
    var template = "{date}_{time}_{counter}"
    var grouping = "none"
    var counter = 1
    var quality = -1
    var resolution = -1
    static let formats = ["jpeg", "png", "tiff", "raw", "dng"]
    var captureCode: Int {
        let raw = format == "raw" ? 1 : (format == "dng" ? 2 : 0)
        return raw + destination * 10 + (quality + 1) * 100 + (resolution + 1) * 1000
    }
    var destinationTitle: String { ["Камера и Mac", "Только камера", "Только Mac"][min(2, max(0, destination))] }
    func validate() throws {
        guard (0...2).contains(destination), Self.formats.contains(format),
              ["datetime", "original", "custom"].contains(naming), ["none", "day", "month"].contains(grouping),
              [-1, 0, 1, 2].contains(quality), [-1, 0, 1, 2, 4, 8].contains(resolution), counter > 0, counter < 1_000_000_000,
              !(destination == 1 && ["png", "tiff"].contains(format)) else { throw CameraFailure(message: "Некорректные настройки сохранения") }
        if naming == "custom" { _ = try basename(original: "IMG_0001.JPG", date: Date()) }
    }
    static func dateText(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = pattern
        return f.string(from: date)
    }
    func directory(folder: URL, date: Date) -> URL {
        guard grouping != "none" else { return folder }
        return folder.appendingPathComponent(Self.dateText(date, grouping == "day" ? "yyyy-MM-dd" : "yyyy-MM"), isDirectory: true)
    }
    func basename(original: String, date: Date) throws -> String {
        if naming == "original" { return URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent }
        if naming == "datetime" { return Self.dateText(date, "yyyy-MM-dd_HH-mm-ss") }
        var result = template
        for (key, value) in ["date": Self.dateText(date, "yyyy-MM-dd"), "time": Self.dateText(date, "HH-mm-ss"), "counter": String(format: "%04d", counter), "original": URL(fileURLWithPath: original).deletingPathExtension().lastPathComponent] {
            result = result.replacingOccurrences(of: "{" + key + "}", with: value)
        }
        guard !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              result.utf8.count <= 180, result != ".", result != "..",
              !result.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !result.contains(where: { "/:\0\n\r{}".contains($0) }) else {
            throw CameraFailure(message: "Недопустимый шаблон имени. Используйте {date}, {time}, {counter}, {original}; без /, : и переносов строк.")
        }
        return result
    }
}
struct CapturedFile: Decodable, Sendable {
    let name: String
    let kind: String
    let size: Int
}
struct SavedCapture: Sendable { let files: [URL]; let preview: URL? }

enum CaptureFiles {
    static func validate(_ url: URL, kind: String, expectedSize: Int? = nil) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, expectedSize == nil || size == expectedSize else { throw CameraFailure(message: "Файл скачан не полностью: " + url.lastPathComponent) }
        if kind == "raw" { return }
        if kind == "dng" {
            let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
            let header = try handle.read(upToCount: 4) ?? Data()
            guard size > 512, header == Data([73,73,42,0]) || header == Data([77,77,0,42]) else { throw CameraFailure(message: "Некорректный контейнер DNG") }
            return
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              CGImageSourceGetCount(source) > 0, CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              CGImageSourceGetType(source) as String? == (kind == "jpeg" ? UTType.jpeg.identifier : (kind == "png" ? UTType.png.identifier : UTType.tiff.identifier)) else { throw CameraFailure(message: "Не удалось проверить изображение: " + url.lastPathComponent) }
    }
    static func save(staging: URL, files: [CapturedFile], settings: SaveSettings, folder: URL, date: Date) throws -> SavedCapture {
        try settings.validate()
        guard let jpeg = files.first(where: { $0.kind == "jpeg" }) else { throw CameraFailure(message: "Камера не вернула JPEG") }
        for file in files {
            guard URL(fileURLWithPath: file.name).lastPathComponent == file.name, !file.name.contains("/"), file.size > 0 else { throw CameraFailure(message: "Некорректное имя скачанного файла") }
            // DNG is checked as a TIFF container here; RAW has no standard decoder.
            try validate(staging.appendingPathComponent(file.name), kind: file.kind, expectedSize: file.size)
        }
        let directory = settings.directory(folder: folder, date: date)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = try settings.basename(original: jpeg.name, date: date)
        var products: [(URL, String)] = []
        if ["png", "tiff"].contains(settings.format) {
            let sourceURL = staging.appendingPathComponent(jpeg.name)
            let converted = staging.appendingPathComponent("converted." + settings.format)
            let type = settings.format == "png" ? UTType.png.identifier : UTType.tiff.identifier
            guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil), let writer = CGImageDestinationCreateWithURL(converted as CFURL, type as CFString, 1, nil) else { throw CameraFailure(message: "Не удалось преобразовать JPEG") }
            CGImageDestinationAddImageFromSource(writer, source, 0, nil)
            guard CGImageDestinationFinalize(writer) else { throw CameraFailure(message: "Ошибка записи преобразованного файла") }
            try validate(converted, kind: settings.format)
            products.append((converted, settings.format))
            if settings.keepJPEG { products.append((sourceURL, "jpg")) }
        } else {
            for file in files { products.append((staging.appendingPathComponent(file.name), file.kind == "jpeg" ? "jpg" : file.kind)) }
        }
        // A single suffix keeps companions together. copyItem refuses existing files;
        // verify all products before allowing deletion of the camera originals.
        var suffix = 0
        while true {
            let stem = base + (suffix == 0 ? "" : "_\(suffix)")
            let targets = products.map { product -> URL in
                let originalBase = product.0.deletingPathExtension().lastPathComponent
                let name = settings.naming == "original" && !product.0.lastPathComponent.hasPrefix("converted.") ? originalBase + (suffix == 0 ? "" : "_\(suffix)") : stem
                return directory.appendingPathComponent(name + "." + product.1)
            }
            if targets.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) { suffix += 1; continue }
            var published: [URL] = []
            do {
                for (index, product) in products.enumerated() {
                    try FileManager.default.copyItem(at: product.0, to: targets[index]); published.append(targets[index])
                }
                for (index, target) in targets.enumerated() {
                    try validate(target, kind: products[index].1 == "jpg" ? "jpeg" : products[index].1)
                    let handle = try FileHandle(forWritingTo: target)
                    do { try handle.synchronize(); try handle.close() }
                    catch { try? handle.close(); throw error }
                }
                return SavedCapture(files: targets, preview: targets.first(where: { ["jpg", "png", "tiff"].contains($0.pathExtension) }))
            } catch {
                for path in published { try? FileManager.default.removeItem(at: path) }
                if targets.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) { suffix += 1; continue }
                throw error
            }
        }
    }
}
