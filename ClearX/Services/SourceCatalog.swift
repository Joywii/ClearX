import Darwin
import Foundation

actor SourceCatalog: ScanSourceCataloging {
    func discoverSources() async -> [ScanSource] {
        var sources = [machineDiskSource()]
        let keys: Set<URLResourceKey> = [
            .volumeIsLocalKey,
            .volumeIsReadOnlyKey,
            .volumeIsBrowsableKey,
            .volumeNameKey,
            .volumeUUIDStringKey
        ]

        guard let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(keys),
            options: [.skipHiddenVolumes]
        ) else {
            return sources
        }

        for url in volumeURLs {
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.volumeIsLocal == true,
                  values?.volumeIsReadOnly != true,
                  values?.volumeIsBrowsable != false,
                  url.standardizedFileURL.path != "/" else {
                continue
            }
            sources.append(ScanSource(kind: .localVolume, rootURL: url, displayName: values?.volumeName ?? url.lastPathComponent, volume: volumeIdentity(for: url)))
        }
        return sources
    }

    func folderSource(for rootURL: URL) -> ScanSource {
        ScanSource(kind: .folder, rootURL: rootURL, displayName: rootURL.lastPathComponent, volume: volumeIdentity(for: rootURL))
    }

    private func machineDiskSource() -> ScanSource {
        let rootURL = URL(fileURLWithPath: "/", isDirectory: true)
        return ScanSource(kind: .machineDisk, rootURL: rootURL, displayName: "本机磁盘", volume: volumeIdentity(for: rootURL))
    }

    private func volumeIdentity(for url: URL) -> VolumeIdentity? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return -1 }
            return Int(stat(path, &info))
        }
        guard result == 0 else { return nil }
        let uuid = (try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
            .flatMap(UUID.init(uuidString:))
        return VolumeIdentity(deviceID: Int64(info.st_dev), volumeUUID: uuid)
    }
}
