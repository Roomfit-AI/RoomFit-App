import Foundation
import UIKit

struct UploadedRoomRecord: Identifiable, Codable {
    let id: UUID
    let roomId: Int
    let name: String
    let thumbnailFileName: String?
    let modelFileName: String?
    let uploadedAt: Date
}

/// Keeps a simple on-device history of rooms this app has uploaded, so the home
/// screen has something to show without needing a "list rooms" backend endpoint.
@MainActor
final class UploadedRoomStore: ObservableObject {
    @Published private(set) var records: [UploadedRoomRecord] = []

    private let recordsFileURL: URL
    private let thumbnailsDirectory: URL
    private let modelsDirectory: URL

    init() {
        let documentsDirectory = (try? FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory

        recordsFileURL = documentsDirectory.appendingPathComponent("UploadedRooms.json")
        thumbnailsDirectory = documentsDirectory.appendingPathComponent("RoomThumbnails", isDirectory: true)
        modelsDirectory = documentsDirectory.appendingPathComponent("RoomModels", isDirectory: true)
        try? FileManager.default.createDirectory(at: thumbnailsDirectory, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        load()
    }

    /// `modelSourceURL` is a temporary file (e.g. a freshly-exported USDZ) that
    /// gets moved into this store's own permanent location.
    func add(roomId: Int, name: String, thumbnail: UIImage?, modelSourceURL: URL?) {
        let thumbnailFileName = saveThumbnail(thumbnail)
        let modelFileName = saveModel(modelSourceURL)
        let record = UploadedRoomRecord(
            id: UUID(),
            roomId: roomId,
            name: name,
            thumbnailFileName: thumbnailFileName,
            modelFileName: modelFileName,
            uploadedAt: Date()
        )
        records.insert(record, at: 0)
        save()
    }

    func thumbnailImage(for record: UploadedRoomRecord) -> UIImage? {
        guard let thumbnailFileName = record.thumbnailFileName else { return nil }
        let url = thumbnailsDirectory.appendingPathComponent(thumbnailFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    func modelURL(for record: UploadedRoomRecord) -> URL? {
        guard let modelFileName = record.modelFileName else { return nil }
        let url = modelsDirectory.appendingPathComponent(modelFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func delete(_ record: UploadedRoomRecord) {
        if let thumbnailFileName = record.thumbnailFileName {
            try? FileManager.default.removeItem(at: thumbnailsDirectory.appendingPathComponent(thumbnailFileName))
        }
        if let modelFileName = record.modelFileName {
            try? FileManager.default.removeItem(at: modelsDirectory.appendingPathComponent(modelFileName))
        }
        records.removeAll { $0.id == record.id }
        save()
    }

    private func saveModel(_ sourceURL: URL?) -> String? {
        guard let sourceURL else { return nil }

        let fileName = "\(UUID().uuidString).usdz"
        let destinationURL = modelsDirectory.appendingPathComponent(fileName)
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            return fileName
        } catch {
            return nil
        }
    }

    private func saveThumbnail(_ image: UIImage?) -> String? {
        guard let image else { return nil }
        let resized = resized(image, maxDimension: 240)
        guard let data = resized.jpegData(compressionQuality: 0.7) else { return nil }

        let fileName = "\(UUID().uuidString).jpg"
        let url = thumbnailsDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: url, options: .atomic)
            return fileName
        } catch {
            return nil
        }
    }

    private func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let scale = min(maxDimension / max(size.width, size.height, 1), 1)
        guard scale < 1 else { return image }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: recordsFileURL) else { return }
        records = (try? JSONDecoder().decode([UploadedRoomRecord].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: recordsFileURL, options: .atomic)
    }
}
