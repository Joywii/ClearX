import AppKit
import Darwin

enum ScanItemAction: CaseIterable {
    case copyPath
    case revealInFinder

    var title: String {
        switch self {
        case .copyPath: "拷贝路径"
        case .revealInFinder: "在 Finder 中显示"
        }
    }
}

enum ScanItemActionFailure: Equatable {
    case unavailable(URL)
    case clipboardUnavailable(URL)

    var url: URL {
        switch self {
        case let .unavailable(url), let .clipboardUnavailable(url): url
        }
    }

    var message: String {
        switch self {
        case .unavailable: "项目已不存在或当前无法访问。"
        case .clipboardUnavailable: "无法将路径写入剪贴板，请重试。"
        }
    }
}

@MainActor
struct ScanItemActions {
    var copyPath: (URL) -> Bool = { Self.writePath($0, to: .general) }
    var revealInFinder: (URL) -> Void = { url in
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
    var itemExists: @Sendable (URL) -> Bool = Self.itemExists(at:)

    static func writePath(_ url: URL, to pasteboard: NSPasteboard) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(url.path, forType: .string)
    }

    func perform(_ action: ScanItemAction, at url: URL) async -> ScanItemActionFailure? {
        guard url.isFileURL else { return .unavailable(url) }
        switch action {
        case .copyPath:
            return copyPath(url) ? nil : .clipboardUnavailable(url)
        case .revealInFinder:
            let exists = await Task.detached(priority: .userInitiated) { [itemExists] in
                itemExists(url)
            }.value
            guard !Task.isCancelled else { return nil }
            guard exists else { return .unavailable(url) }
            revealInFinder(url)
            return nil
        }
    }

    nonisolated static func itemExists(at url: URL) -> Bool {
        guard url.isFileURL else { return false }
        // lstat checks the entry itself, including dangling links. A trailing
        // directory slash must not turn that lookup into following its target.
        let entryURL = URL(fileURLWithPath: url.path, isDirectory: false)
        var info = stat()
        return entryURL.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return lstat(path, &info) == 0
        }
    }
}
