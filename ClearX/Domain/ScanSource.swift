import Foundation

struct ScanSourceID: RawRepresentable, Hashable, Codable, Sendable, Identifiable {
    let rawValue: UUID

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    var id: UUID { rawValue }
}

struct VolumeIdentity: Hashable, Codable, Sendable {
    /// `st_dev` is stable for the duration of a mounted volume and does not expose a path.
    let deviceID: Int64
    let volumeUUID: UUID?

    init(deviceID: Int64, volumeUUID: UUID? = nil) {
        self.deviceID = deviceID
        self.volumeUUID = volumeUUID
    }
}

enum ScanSourceKind: String, Codable, Sendable {
    case machineDisk
    case localVolume
    case folder
}

struct ScanSource: Identifiable, Hashable, Codable, Sendable {
    let id: ScanSourceID
    let kind: ScanSourceKind
    let rootURL: URL
    let displayName: String
    let volume: VolumeIdentity?

    init(id: ScanSourceID = ScanSourceID(), kind: ScanSourceKind, rootURL: URL, displayName: String? = nil, volume: VolumeIdentity? = nil) {
        self.id = id
        self.kind = kind
        self.rootURL = rootURL.standardizedFileURL
        self.displayName = displayName ?? rootURL.lastPathComponent
        self.volume = volume
    }
}

enum ScanSourceAvailability: String, Codable, Sendable {
    case available
    case unavailable
    case cacheCleared
}
