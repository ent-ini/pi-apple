import Testing
@testable import ApplePi

@Test func attachmentPreviewFilenamePrefersDisplayNameWithExtension() {
    #expect(
        AttachmentPreviewFilename.resolve(
            downloadedName: "attachment",
            displayName: "photo.png",
            mimeType: "image/png"
        ) == "photo.png"
    )
}

@Test func attachmentPreviewFilenameInfersExtensionFromMimeType() {
    #expect(
        AttachmentPreviewFilename.resolve(
            downloadedName: "33050433-7219-4DA5-BA65-FFD5CDC5C348-Image",
            displayName: "Image",
            mimeType: "image/png"
        ) == "33050433-7219-4DA5-BA65-FFD5CDC5C348-Image.png"
    )
}

@Test func attachmentPreviewFilenamePreservesServerExtension() {
    #expect(
        AttachmentPreviewFilename.resolve(
            downloadedName: "server-photo.heic",
            displayName: "Image",
            mimeType: "image/jpeg"
        ) == "server-photo.heic"
    )
}
