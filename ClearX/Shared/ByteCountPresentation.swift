import Foundation

enum ByteCountPresentation {
    static func string(for byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}
