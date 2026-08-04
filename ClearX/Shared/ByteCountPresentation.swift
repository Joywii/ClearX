import Foundation

enum ByteCountPresentation {
    static func string(for byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    static func proportionString(itemSize: Int64, parentSize: Int64?) -> String? {
        guard let parentSize, parentSize > 0 else {
            return nil
        }

        let percentage = (Double(itemSize) / Double(parentSize)) * 100
        return String(format: "%.1f%%", percentage)
    }
}
