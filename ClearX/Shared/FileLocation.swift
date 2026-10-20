import Foundation
import Darwin

/// Compare physical ancestors by components, without following a leaf link.
enum FileLocation {
    static func resolved(_ url: URL) -> URL {
        let url = url.standardizedFileURL
        let path = url.withUnsafeFileSystemRepresentation { pointer -> String? in
            guard let pointer, let result = realpath(pointer, nil) else { return nil }
            defer { free(result) }
            return String(cString: result)
        }
        if let path { return URL(fileURLWithPath: path) }
        guard url.path != "/" else { return url }
        // Missing leaves must use the same physical spelling as existing ancestors.
        return resolved(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent)
    }

    static func entry(_ url: URL) -> URL {
        guard url.path != "/" else { return url.standardizedFileURL }
        return resolved(url.deletingLastPathComponent()).appendingPathComponent(url.lastPathComponent).standardizedFileURL
    }

    static func contains(_ parent: URL, _ child: URL) -> Bool {
        child.standardizedFileURL.pathComponents.starts(with: parent.standardizedFileURL.pathComponents)
    }

    static func overlaps(_ lhs: URL, _ rhs: URL) -> Bool {
        contains(lhs, rhs) || contains(rhs, lhs)
    }
}
