import AppKit

@MainActor
protocol ApplicationIconProviding: AnyObject {
    func icon(for path: String?) -> NSImage?
}

@MainActor
final class ApplicationIconStore: ApplicationIconProviding {
    private let fileExists: (String) -> Bool
    private let loadIcon: (String) -> NSImage
    private let cache = NSCache<NSString, NSImage>()

    init(
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        loadIcon: @escaping (String) -> NSImage = { NSWorkspace.shared.icon(forFile: $0) }
    ) {
        self.fileExists = fileExists
        self.loadIcon = loadIcon
    }

    func icon(for path: String?) -> NSImage? {
        guard let path, !path.isEmpty, fileExists(path) else { return nil }
        let key = path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = loadIcon(path)
        cache.setObject(icon, forKey: key)
        return icon
    }
}
