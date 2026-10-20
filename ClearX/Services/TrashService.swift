import Foundation
import Darwin

struct TrashTarget: Identifiable, Sendable {
    let node: ScanNodeSummary
    let device: Int32
    let inode: UInt64
    var id: ScanNodeID { node.id }
}

struct TrashAssessment: Sendable {
    let targets: [TrashTarget]
    let disabledReason: String?
}

struct TrashReport: Sendable {
    struct Failure: Sendable {
        let url: URL
        let reason: String
    }
    var succeeded: [URL] = []
    var failures: [Failure] = []
    var unprocessed = 0
}

actor TrashService {
    static let shared = TrashService()
    private let coordinator: ScanCoordinator
    private let cache: InMemoryScanCache
    private let inspect: @Sendable ([ScanNodeSummary], URL) -> TrashAssessment
    private let move: @Sendable (URL) throws -> Void

    init(coordinator: ScanCoordinator = .shared, cache: InMemoryScanCache = .shared,
         inspect: @escaping @Sendable ([ScanNodeSummary], URL) -> TrashAssessment = TrashService.inspect,
         move: @escaping @Sendable (URL) throws -> Void = { url in
             _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
         }) {
        self.coordinator = coordinator
        self.cache = cache
        self.inspect = inspect
        self.move = move
    }

    func assess(_ nodes: [ScanNodeSummary], root: URL) async -> TrashAssessment {
        let result = inspect(nodes, root)
        guard result.disabledReason == nil else { return result }
        let reason = await coordinator.fileOperationBlockReason(for: nodes.map(\.url))
        return TrashAssessment(targets: result.targets, disabledReason: reason)
    }

    func execute(_ targets: [TrashTarget], root: URL,
                 progress: @Sendable (Int) async -> Void = { _ in }) async -> TrashReport {
        var report = TrashReport(unprocessed: targets.count)
        let urls = targets.map { $0.node.url }
        guard !Task.isCancelled else { return report }
        guard let lease = await coordinator.beginFileOperation(urls: urls) else {
            report.failures = urls.map { .init(url: $0, reason: "存在重叠的扫描或文件操作，请稍后重试。") }
            report.unprocessed = 0
            return report
        }
        // Recheck the entire confirmed batch before moving any item.
        let current = inspect(targets.map(\.node), root)
        let identitiesMatch = current.targets.count == targets.count && zip(current.targets, targets).allSatisfy {
            $0.id == $1.id && $0.device == $1.device && $0.inode == $1.inode
        }
        if let reason = current.disabledReason ?? (identitiesMatch ? nil : "项目已被替换，请重新选择并确认。") {
            report.failures = urls.map { .init(url: $0, reason: reason) }
            report.unprocessed = 0
        } else {
            for target in targets {
                if Task.isCancelled { break }
                let checked = inspect([target.node], root)
                let same = checked.targets.first.map { $0.device == target.device && $0.inode == target.inode } ?? false
                do {
                    if let reason = checked.disabledReason ?? (same ? nil : "项目已被替换。") {
                        throw TrashError(reason: reason)
                    }
                    try move(target.node.url)
                    report.succeeded.append(target.node.url)
                } catch {
                    report.failures.append(.init(url: target.node.url, reason: error.localizedDescription))
                }
                report.unprocessed -= 1
                await progress(targets.count - report.unprocessed)
            }
        }
        // Invalidate before releasing the lease, so a queued scan cannot read old cache.
        await cache.invalidate(overlapping: report.succeeded)
        await coordinator.endFileOperation(lease)
        return report
    }

    nonisolated static func inspect(_ nodes: [ScanNodeSummary], root: URL) -> TrashAssessment {
        let manager = FileManager.default
        var targets: [TrashTarget] = []
        guard let mounts = try? ScanMountPoints.read() else {
            return TrashAssessment(targets: [], disabledReason: "无法核实卷挂载信息。")
        }
        for node in nodes {
            let url = URL(fileURLWithPath: node.url.path, isDirectory: false)
            var info = stat()
            let exists = url.withUnsafeFileSystemRepresentation { $0.map { lstat($0, &info) == 0 } ?? false }
            let canonical = FileLocation.entry(url)
            let isDirectory = (info.st_mode & S_IFMT) == S_IFDIR
            let reason: String?
            if !node.url.isFileURL || !exists {
                reason = "项目已不存在或无法访问。"
            } else if canonical.path == FileLocation.resolved(root).path || node.kind == .mountPoint {
                reason = "扫描根目录和卷挂载点受到保护。"
            } else if mounts.protectsEntry(canonical, includeDescendants: isDirectory) {
                reason = "该项目是挂载点或内部包含已挂载的卷。"
            } else {
                var relationship = FileManager.URLRelationship.other
                do {
                    try manager.getRelationship(&relationship, of: .trashDirectory,
                                                in: .allDomainsMask, toItemAt: url)
                    if relationship != .other {
                        reason = "废纸篓及其内部项目受到保护。"
                    } else if !manager.isDeletableFile(atPath: url.path) {
                        reason = "系统判定当前用户不可删除此项目。"
                    } else {
                        reason = nil
                    }
                } catch {
                    reason = "无法核实项目与废纸篓的关系：\(error.localizedDescription)"
                }
            }
            if let reason { return TrashAssessment(targets: [], disabledReason: "\(node.name)：\(reason)") }
            targets.append(TrashTarget(node: node, device: info.st_dev, inode: info.st_ino))
        }
        return TrashAssessment(targets: targets, disabledReason: nodes.isEmpty ? "没有选中项目。" : nil)
    }
}

private struct TrashError: LocalizedError {
    let reason: String
    var errorDescription: String? { reason }
}
