import Foundation
import UniformTypeIdentifiers

/// Gives Quick Look and Save panels a usable filename even when an attachment
/// was uploaded with a generic or extensionless display name.
enum AttachmentPreviewFilename {
    static func resolve(downloadedName: String?, displayName: String?, mimeType: String?) -> String {
        let downloaded = safeName(downloadedName)
        let display = safeName(displayName)

        if let downloaded, hasExtension(downloaded) {
            return downloaded
        }
        if let display, hasExtension(display) {
            return display
        }

        let base = (downloaded == "attachment" ? nil : downloaded) ?? display ?? downloaded ?? "attachment"
        guard let preferredExtension = filenameExtension(for: mimeType) else {
            return base
        }
        return URL(fileURLWithPath: base).appendingPathExtension(preferredExtension).lastPathComponent
    }

    private static func safeName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let parts = value.components(separatedBy: CharacterSet(charactersIn: "/\\:"))
            .filter { !$0.isEmpty }
        let name = parts.joined(separator: "-")
        return name.isEmpty ? nil : name
    }

    private static func hasExtension(_ name: String) -> Bool {
        !URL(fileURLWithPath: name).pathExtension.isEmpty
    }

    private static func filenameExtension(for mimeType: String?) -> String? {
        let mime = mimeType?
            .split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let mime, !mime.isEmpty else { return nil }
        if let type = UTType(mimeType: mime), let ext = type.preferredFilenameExtension {
            return ext
        }
        switch mime {
        case "image/jpg": return "jpg"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        default: return nil
        }
    }
}
