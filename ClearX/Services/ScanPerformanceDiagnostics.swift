import Darwin
import Foundation
import OSLog

struct DirectoryEnumerationPerformanceSample: Sendable {
    let childCount: Int
    let listingNanos: UInt64
    let metadataNanos: UInt64
    let isUnreadable: Bool

    var totalNanos: UInt64 {
        listingNanos &+ metadataNanos
    }
}

struct SlowDirectoryPerformanceSample: Sendable {
    var nanos: UInt64 = 0
    var depth = 0
    var childCount = 0

    mutating func record(nanos: UInt64, depth: Int, childCount: Int) {
        guard nanos > self.nanos else { return }
        self.nanos = nanos
        self.depth = depth
        self.childCount = childCount
    }

    mutating func merge(_ other: Self) {
        record(nanos: other.nanos, depth: other.depth, childCount: other.childCount)
    }
}

struct ScanWorkerPerformanceMetrics: Sendable {
    let workerID: Int
    let startedAtNanos: UInt64
    var directoryCount = 0
    var discoveredItemCount = 0
    var unreadableDirectoryCount = 0
    var listingNanos: UInt64 = 0
    var metadataNanos: UInt64 = 0
    var permitWaitNanos: UInt64 = 0
    var accumulatorApplyNanos: UInt64 = 0
    var accumulatorFinishNanos: UInt64 = 0
    var queueNanos: UInt64 = 0
    var slowestEnumeration = SlowDirectoryPerformanceSample()
    var slowestAccumulatorApply = SlowDirectoryPerformanceSample()

    init(workerID: Int, startedAtNanos: UInt64 = DispatchTime.now().uptimeNanoseconds) {
        self.workerID = workerID
        self.startedAtNanos = startedAtNanos
    }

    mutating func recordEnumeration(_ sample: DirectoryEnumerationPerformanceSample, depth: Int, permitAndEnumerationNanos: UInt64) {
        directoryCount += 1
        discoveredItemCount += sample.childCount
        unreadableDirectoryCount += sample.isUnreadable ? 1 : 0
        listingNanos &+= sample.listingNanos
        metadataNanos &+= sample.metadataNanos
        permitWaitNanos &+= permitAndEnumerationNanos > sample.totalNanos ? permitAndEnumerationNanos - sample.totalNanos : 0
        slowestEnumeration.record(nanos: sample.totalNanos, depth: depth, childCount: sample.childCount)
    }

    mutating func recordAccumulatorApply(nanos: UInt64, depth: Int, childCount: Int) {
        accumulatorApplyNanos &+= nanos
        slowestAccumulatorApply.record(nanos: nanos, depth: depth, childCount: childCount)
    }

    mutating func merge(_ other: Self) {
        directoryCount += other.directoryCount
        discoveredItemCount += other.discoveredItemCount
        unreadableDirectoryCount += other.unreadableDirectoryCount
        listingNanos &+= other.listingNanos
        metadataNanos &+= other.metadataNanos
        permitWaitNanos &+= other.permitWaitNanos
        accumulatorApplyNanos &+= other.accumulatorApplyNanos
        accumulatorFinishNanos &+= other.accumulatorFinishNanos
        queueNanos &+= other.queueNanos
        slowestEnumeration.merge(other.slowestEnumeration)
        slowestAccumulatorApply.merge(other.slowestAccumulatorApply)
    }
}

struct DirectoryQueuePerformanceSnapshot: Sendable {
    let enqueuedCount: Int
    let dequeuedCount: Int
    let peakPendingCount: Int
    let focusPromotionCount: Int
    let staleEntryCount: Int
}

struct ProgressPublisherPerformanceSnapshot: Sendable {
    let submissionCount: Int
    let deliveryCount: Int
    let snapshotNanos: UInt64
    let sinkNanos: UInt64
    let snapshotNodeCount: Int
    let maximumSnapshotNodeCount: Int
}

enum ScanPerformanceDiagnostics {
    private static let logger = Logger(subsystem: "com.hang.clearx", category: "ScanPerformance")
    private static let checkpointDirectoryInterval = 10_000

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CLEARX_SCAN_METRICS"] == "1"
    }

    static func makeScanID() -> String {
        String(UUID().uuidString.prefix(8))
    }

    static func checkpointIfNeeded(scanID: String, metrics: ScanWorkerPerformanceMetrics) {
        guard metrics.directoryCount > 0,
              metrics.directoryCount.isMultiple(of: checkpointDirectoryInterval) else {
            return
        }
        let elapsedNanos = elapsed(since: metrics.startedAtNanos)
        emit(
            "checkpoint scan=\(scanID) worker=\(metrics.workerID) elapsed_ms=\(milliseconds(elapsedNanos)) dirs=\(metrics.directoryCount) items=\(metrics.discoveredItemCount) dirs_per_s=\(rate(metrics.directoryCount, elapsedNanos)) list_ms=\(milliseconds(metrics.listingNanos)) lstat_ms=\(milliseconds(metrics.metadataNanos)) permit_wait_ms=\(milliseconds(metrics.permitWaitNanos)) apply_ms=\(milliseconds(metrics.accumulatorApplyNanos)) finish_ms=\(milliseconds(metrics.accumulatorFinishNanos))"
        )
    }

    static func final(
        scanID: String,
        result: ScanResult,
        metrics: ScanWorkerPerformanceMetrics,
        queue: DirectoryQueuePerformanceSnapshot,
        publisher: ProgressPublisherPerformanceSnapshot,
        elapsedNanos: UInt64,
        finalizationNanos: UInt64,
        resultMaterializationNanos: UInt64
    ) {
        guard isEnabled else { return }
        let status: String
        switch result.status {
        case .complete:
            status = "complete"
        case .incomplete:
            status = "incomplete"
        }
        let residentMB = residentMemoryBytes().map { String(format: "%.1f", Double($0) / 1_048_576) } ?? "unknown"
        emit(
            "final scan=\(scanID) status=\(status) elapsed_ms=\(milliseconds(elapsedNanos)) nodes=\(result.nodes.count) dirs=\(metrics.directoryCount) items=\(metrics.discoveredItemCount) nodes_per_s=\(rate(result.nodes.count, elapsedNanos)) resident_mb=\(residentMB) list_ms=\(milliseconds(metrics.listingNanos)) lstat_ms=\(milliseconds(metrics.metadataNanos)) permit_wait_ms=\(milliseconds(metrics.permitWaitNanos)) apply_ms=\(milliseconds(metrics.accumulatorApplyNanos)) finish_ms=\(milliseconds(metrics.accumulatorFinishNanos)) queue_ms=\(milliseconds(metrics.queueNanos)) progress_snapshot_ms=\(milliseconds(publisher.snapshotNanos)) progress_sink_ms=\(milliseconds(publisher.sinkNanos)) progress_publications=\(publisher.deliveryCount) snapshot_nodes=\(publisher.snapshotNodeCount) snapshot_nodes_max=\(publisher.maximumSnapshotNodeCount) finalize_ms=\(milliseconds(finalizationNanos)) result_build_ms=\(milliseconds(resultMaterializationNanos))"
        )
        emit(
            "queue scan=\(scanID) enqueued=\(queue.enqueuedCount) dequeued=\(queue.dequeuedCount) peak_pending=\(queue.peakPendingCount) promotions=\(queue.focusPromotionCount) stale_entries=\(queue.staleEntryCount)"
        )
        emit(
            "publisher scan=\(scanID) submissions=\(publisher.submissionCount) deliveries=\(publisher.deliveryCount) merge_ms=0.00 sink_ms=\(milliseconds(publisher.sinkNanos)) pending_nodes_max=0 snapshot_ms=\(milliseconds(publisher.snapshotNanos)) snapshot_nodes=\(publisher.snapshotNodeCount) snapshot_nodes_max=\(publisher.maximumSnapshotNodeCount)"
        )
        emit(
            "slow scan=\(scanID) enumerate_ms=\(milliseconds(metrics.slowestEnumeration.nanos)) enumerate_depth=\(metrics.slowestEnumeration.depth) enumerate_children=\(metrics.slowestEnumeration.childCount) apply_ms=\(milliseconds(metrics.slowestAccumulatorApply.nanos)) apply_depth=\(metrics.slowestAccumulatorApply.depth) apply_children=\(metrics.slowestAccumulatorApply.childCount) unreadable_dirs=\(metrics.unreadableDirectoryCount)"
        )
    }

    static func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    static func elapsed(since start: UInt64) -> UInt64 {
        let end = now()
        return end >= start ? end - start : 0
    }

    private static func milliseconds(_ nanos: UInt64) -> String {
        String(format: "%.2f", Double(nanos) / 1_000_000)
    }

    private static func rate(_ count: Int, _ elapsedNanos: UInt64) -> String {
        guard elapsedNanos > 0 else { return "0" }
        return String(format: "%.1f", Double(count) * 1_000_000_000 / Double(elapsedNanos))
    }

    private static func emit(_ message: String) {
        logger.notice("CLEARX_SCAN \(message, privacy: .public)")
    }

    private static func residentMemoryBytes() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }
}
