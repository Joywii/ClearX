import Foundation

struct EventCheckpoint: Hashable, Codable, Sendable {
    let eventID: UInt64
    let volume: VolumeIdentity

    init(eventID: UInt64, volume: VolumeIdentity) {
        self.eventID = eventID
        self.volume = volume
    }
}

struct FileSystemEventFlags: OptionSet, Hashable, Sendable {
    let rawValue: UInt32

    init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    static let mustScanSubDirectories = Self(rawValue: 1 << 0)
    static let userDropped = Self(rawValue: 1 << 1)
    static let kernelDropped = Self(rawValue: 1 << 2)
    static let rootChanged = Self(rawValue: 1 << 3)
    static let eventIDsWrapped = Self(rawValue: 1 << 4)

    var requiresFullRescan: Bool {
        !intersection([.mustScanSubDirectories, .userDropped, .kernelDropped, .rootChanged, .eventIDsWrapped]).isEmpty
    }
}

struct FileSystemEvent: Hashable, Sendable {
    let id: UInt64
    let url: URL
    let flags: FileSystemEventFlags

    init(id: UInt64, url: URL, flags: FileSystemEventFlags = []) {
        self.id = id
        self.url = url.standardizedFileURL
        self.flags = flags
    }
}

struct EventReplay: Sendable {
    let events: [FileSystemEvent]
    let highWaterMark: UInt64
    let completed: Bool

    init(events: [FileSystemEvent], highWaterMark: UInt64, completed: Bool) {
        self.events = events
        self.highWaterMark = highWaterMark
        self.completed = completed
    }
}

enum EventValidation: Sendable, Hashable {
    case cacheValid(EventCheckpoint)
    case refreshBranches(urls: [URL], checkpoint: EventCheckpoint)
    case fullRescan(reason: EventRescanReason)
}

enum EventRescanReason: String, Sendable, Hashable {
    case replayIncomplete
    case eventHistoryLost
    case ambiguousFlags
    case discontinuousEventIDs
    case pathOutsideRoot
    case pathOutsideVolume
    case pathCannotBeNormalized
}
