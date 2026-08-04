import Foundation

struct ScanNodeID: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var id: UUID { rawValue }
}

enum ScanNodeKind: String, Codable, Sendable {
    case directory
    case file
    case other
}

struct ScanNodeSummary: Identifiable, Hashable, Codable, Sendable {
    let id: ScanNodeID
    let parentID: ScanNodeID?
    let url: URL
    let kind: ScanNodeKind
    let allocatedSize: Int64
    let modificationDate: Date?
    let countsTowardAllocatedSize: Bool
    let isIncomplete: Bool

    init(
        id: ScanNodeID = ScanNodeID(),
        parentID: ScanNodeID?,
        url: URL,
        kind: ScanNodeKind,
        allocatedSize: Int64,
        modificationDate: Date? = nil,
        countsTowardAllocatedSize: Bool = true,
        isIncomplete: Bool = false
    ) {
        self.id = id
        self.parentID = parentID
        self.url = url.standardizedFileURL
        self.kind = kind
        self.allocatedSize = max(0, allocatedSize)
        self.modificationDate = modificationDate
        self.countsTowardAllocatedSize = countsTowardAllocatedSize
        self.isIncomplete = isIncomplete
    }

    /// Presentation derives the local name from its URL; no raw filesystem path crosses the domain API.
    var name: String {
        url.path == "/" ? "/" : url.lastPathComponent
    }

    static func browserOrder(_ lhs: ScanNodeSummary, _ rhs: ScanNodeSummary) -> Bool {
        if lhs.allocatedSize != rhs.allocatedSize {
            return lhs.allocatedSize > rhs.allocatedSize
        }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
