import Combine
import Foundation

extension Notification.Name {
    static let clearXFilesTrashed = Notification.Name("ClearXFilesTrashed")
}

@MainActor
final class TrashOperationModel: ObservableObject {
    @Published private(set) var targets: [TrashTarget] = []
    @Published private(set) var isPresented = false
    @Published private(set) var isRunning = false
    @Published private(set) var completedCount = 0
    @Published private(set) var report: TrashReport?
    @Published private(set) var error: String?
    private var task: Task<Void, Never>?
    private let service: TrashService

    init(service: TrashService = .shared) { self.service = service }

    func prepare(_ nodes: [ScanNodeSummary], root: URL) {
        guard !isPresented else { return }
        isPresented = true
        targets = []
        report = nil
        error = nil
        completedCount = 0
        task = Task {
            let assessment = await service.assess(nodes, root: root)
            guard !Task.isCancelled else { return }
            targets = assessment.targets
            error = assessment.disabledReason
        }
    }

    func confirm(root: URL) {
        guard !isRunning, !targets.isEmpty, error == nil, report == nil else { return }
        isRunning = true
        let confirmed = targets
        task = Task {
            let result = await service.execute(confirmed, root: root) { [weak self] count in
                await self?.updateProgress(count)
            }
            report = result
            isRunning = false
            if !result.succeeded.isEmpty {
                NotificationCenter.default.post(name: .clearXFilesTrashed, object: result.succeeded)
            }
        }
    }

    func stop() { task?.cancel() }

    func dismiss() {
        guard !isRunning else { return }
        task?.cancel()
        isPresented = false
    }

    private func updateProgress(_ count: Int) { completedCount = count }
}
