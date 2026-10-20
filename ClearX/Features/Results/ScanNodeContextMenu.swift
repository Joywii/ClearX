import AppKit

/// A menu owns its original ID, URL and handlers even if scan sorting moves its row.
@MainActor
final class ScanNodeMenuSession: NSObject {
    let menu = NSMenu()
    let nodeID: ScanNodeID
    let url: URL
    private let onTrackingChange: (ScanNodeID?) -> Void
    private let onAction: (ScanItemAction, URL) -> Void
    private let trashNodes: [ScanNodeSummary]?
    private let root: URL?
    private let onTrash: (([ScanNodeSummary]) -> Void)?
    private var trashItem: NSMenuItem?
    private var validationTask: Task<Void, Never>?
    private var validationTimer: Timer?
    private var isTracking = false

    init(node: ScanNodeSummary, onTrackingChange: @escaping (ScanNodeID?) -> Void,
         onAction: @escaping (ScanItemAction, URL) -> Void,
         trashNodes: [ScanNodeSummary]? = nil, root: URL? = nil,
         onTrash: (([ScanNodeSummary]) -> Void)? = nil, showsTrash: Bool = true) {
        nodeID = node.id
        url = node.url
        self.onTrackingChange = onTrackingChange
        self.onAction = onAction
        self.trashNodes = trashNodes
        self.root = root
        self.onTrash = onTrash
        super.init()
        menu.autoenablesItems = false
        for action in (trashNodes?.count ?? 1) > 1 ? [] : ScanItemAction.allCases {
            let item = NSMenuItem(title: action.title, action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            menu.addItem(item)
        }
        if showsTrash, trashNodes != nil {
            let item = NSMenuItem(title: "移到废纸篓（正在检查…）", action: #selector(performTrash), keyEquivalent: "")
            item.target = self
            item.isEnabled = false
            menu.addItem(item)
            trashItem = item
        }
    }

    func beginTracking() {
        isTracking = true
        onTrackingChange(nodeID)
        guard trashItem != nil else { return }
        validateTrash()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.validateTrash() }
        }
        validationTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    func endTracking() {
        isTracking = false
        validationTask?.cancel()
        validationTimer?.invalidate()
        validationTimer = nil
        onTrackingChange(nil)
    }

    private func validateTrash() {
        guard validationTask == nil, let trashNodes, let root else { return }
        validationTask = Task { [weak self] in
            let assessment = await TrashService.shared.assess(trashNodes, root: root)
            guard let self else { return }
            defer { validationTask = nil }
            guard isTracking, !Task.isCancelled else { return }
            trashItem?.isEnabled = assessment.disabledReason == nil
            trashItem?.title = assessment.disabledReason == nil ? "移到废纸篓" : "移到废纸篓（不可用）"
            trashItem?.toolTip = assessment.disabledReason
            trashItem?.setAccessibilityHelp(assessment.disabledReason)
        }
    }

    @objc private func performTrash() {
        guard let trashNodes, trashItem?.isEnabled == true else { return }
        onTrash?(trashNodes)
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? ScanItemAction else { return }
        onAction(action, url)
    }
}
