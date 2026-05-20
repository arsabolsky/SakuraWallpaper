import Foundation

public enum MediaType: Equatable {
    case video, gif, image, unsupported

    public static func detect(_ url: URL) -> MediaType {
        let ext = url.pathExtension.lowercased()
        if ["mp4", "mov", "m4v"].contains(ext) { return .video }
        if ext == "gif" { return .gif }
        if ["png", "jpg", "jpeg", "heic", "heif", "webp", "bmp", "tiff"].contains(ext) { return .image }
        return .unsupported
    }
}
