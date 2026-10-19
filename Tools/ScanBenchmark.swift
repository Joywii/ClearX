import Darwin
import Foundation

/// Compile with the scan domain and services, not as part of the application target.
@main
struct ScanBenchmark {
    static func main() async {
        do {
            try await run()
        } catch {
            FileHandle.standardError.write(Data("Benchmark failed: \(error)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    private static func run() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, ["fixture", "scan", "cache"].contains(arguments[1]) else {
            FileHandle.standardError.write(Data("Usage: ScanBenchmark fixture|scan|cache DIRECTORY\n".utf8))
            exit(EX_USAGE)
        }

        let root = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
        if arguments[1] == "cache" {
            try await measureCachedColumn(root: root)
            return
        }
        if arguments[1] == "fixture" {
            // Refuse to reuse an existing directory so fixture generation cannot overwrite user data.
            let created = root.withUnsafeFileSystemRepresentation { path in
                path.map { mkdir($0, S_IRWXU) } ?? -1
            }
            guard created == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let payload = Data(repeating: 1, count: 1)
            for directory in 0..<1_000 {
                let child = root.appending(path: "directory-\(directory)", directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false)
                for file in 0..<100 {
                    try payload.write(to: child.appending(path: "file-\(file)"), options: .withoutOverwriting)
                }
            }
            print("fixture directories=1001 files=100000")
            return
        }

        let source = ScanSource(kind: .folder, rootURL: root)
        let sampler = ScanMemorySampler()
        let samplingTask = Task { await sampler.samplePeriodically() }
        let start = ContinuousClock.now
        let result = try await FileTreeScanner().scan(
            source: source,
            request: ScanRequest(rootURL: root, sourceID: source.id)
        )
        let elapsed = start.duration(to: .now)
        samplingTask.cancel()
        await samplingTask.value
        let memory = await sampler.finish()
        let rootNode = await result.snapshot.rootNode()
        let summary = await result.snapshot.sizeSummary()
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("scan seconds=\(seconds) nodes=\(result.nodeCount) content_bytes=\(rootNode?.allocatedSize ?? 0) unique_bytes=\(summary.uniqueAllocatedSize) status=\(result.status) peak_bytes=\(memory.peakBytes ?? 0)")
    }

    private static func measureCachedColumn(root: URL) async throws {
        let source = ScanSource(kind: .folder, rootURL: root)
        let cache = InMemoryScanCache()
        await cache.retain(source: source)
        // Fixture construction is outside the timed cache lookup and first-page query.
        await populateCache(cache, source: source)
        let start = ContinuousClock.now
        guard let result = await cache.result(for: source),
              let rootNode = await result.snapshot.rootNode() else {
            throw CocoaError(.fileReadUnknown)
        }
        let page = await result.snapshot.page(parentID: rootNode.id, offset: 0, limit: 250)
        let elapsed = start.duration(to: .now)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        precondition(result.nodeCount == 1_000_000 && page.nodes.count == 250 && page.totalCount == 999)
        print("cache nodes=\(result.nodeCount) first_page_seconds=\(seconds) rows=\(page.nodes.count)")
        await cache.release(source: source)
    }

    private static func populateCache(_ cache: InMemoryScanCache, source: ScanSource) async {
        let root = ScanNodeSummary(parentID: nil, url: source.rootURL, kind: .directory, allocatedSize: 999_000 * 4_096)
        var nodes = [root]
        nodes.reserveCapacity(1_000_000)
        for directory in 0..<999 {
            let child = ScanNodeSummary(
                parentID: root.id,
                url: root.url.appending(path: "directory-\(directory)", directoryHint: .isDirectory),
                kind: .directory,
                allocatedSize: 1_000 * 4_096
            )
            nodes.append(child)
            for file in 0..<1_000 {
                nodes.append(ScanNodeSummary(parentID: child.id, url: child.url.appending(path: "file-\(file)"), kind: .file, allocatedSize: 4_096))
            }
        }
        await cache.store(ScanResult(source: source, nodes: nodes, status: .complete))
    }
}
