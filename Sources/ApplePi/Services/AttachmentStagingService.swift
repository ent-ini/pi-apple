import AppKit
import Foundation
import UniformTypeIdentifiers
import ApplePiCore
import ApplePiRemote

struct AttachmentStagingService {
    func stageFile(at sourceURL: URL) throws -> ChatAttachment {
        let scoped = sourceURL.startAccessingSecurityScopedResource()
        defer { if scoped { sourceURL.stopAccessingSecurityScopedResource() } }
        let displayName = sourceURL.lastPathComponent.nilIfBlank ?? "attachment"
        let destinationURL = try makeDestinationURL(
            suggestedName: displayName,
            preferredExtension: sourceURL.pathExtension.nilIfBlank
        )

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)

        let values = try destinationURL.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        let type = values.contentType
        return ChatAttachment(
            kind: chatAttachmentKind(for: type),
            fileURL: destinationURL,
            displayName: displayName,
            mimeType: type?.preferredMIMEType,
            size: values.fileSize.map(Int64.init)
        )
    }

    func stagePastedImage(from pasteboard: NSPasteboard) throws -> ChatAttachment? {
        if let image = pasteboard.readObjects(forClasses: [NSImage.self])?.first as? NSImage,
           let pngData = pngData(for: image) {
            return try stageImageData(pngData, suggestedName: "pasted-image.png")
        }

        if let tiffData = pasteboard.data(forType: .tiff),
           let image = NSImage(data: tiffData),
           let pngData = pngData(for: image) {
            return try stageImageData(pngData, suggestedName: "pasted-image.png")
        }

        return nil
    }

    func stageImageData(_ data: Data, suggestedName: String) throws -> ChatAttachment {
        let destinationURL = try makeDestinationURL(
            suggestedName: suggestedName,
            preferredExtension: URL(fileURLWithPath: suggestedName).pathExtension.nilIfBlank ?? "png"
        )
        try data.write(to: destinationURL, options: .atomic)
        return ChatAttachment(
            kind: .image,
            fileURL: destinationURL,
            displayName: suggestedName,
            mimeType: UTType.png.preferredMIMEType,
            size: Int64(data.count)
        )
    }

    private func pngData(for image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData) else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }

    private func makeDestinationURL(suggestedName: String, preferredExtension: String?) throws -> URL {
        let directory = try stagingDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let baseName = URL(fileURLWithPath: suggestedName).deletingPathExtension().lastPathComponent
        let sanitizedBase = baseName.isEmpty ? "attachment" : baseName
        let ext = preferredExtension?.trimmingCharacters(in: .whitespacesAndNewlines)
        let uniqueName = "\(sanitizedBase)-\(UUID().uuidString)"
        if let ext, !ext.isEmpty {
            return directory.appendingPathComponent(uniqueName).appendingPathExtension(ext)
        }
        return directory.appendingPathComponent(uniqueName)
    }

    private func stagingDirectoryURL() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appendingPathComponent("ApplePi/attachments", isDirectory: true)
    }

    private func chatAttachmentKind(for type: UTType?) -> ChatAttachment.Kind {
        guard let type else { return .file }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .audio) { return .audio }
        return .file
    }
}
