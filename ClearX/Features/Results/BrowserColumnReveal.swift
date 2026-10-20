import AppKit
import SwiftUI

struct BrowserColumnGeometry: Equatable {
    let parentID: ScanNodeID?
    let frame: CGRect
}

struct BrowserColumnFramesKey: PreferenceKey {
    static var defaultValue: [Int: BrowserColumnGeometry] { [:] }

    static func reduce(value: inout [Int: BrowserColumnGeometry], nextValue: () -> [Int: BrowserColumnGeometry]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// Keep the current viewport occupied when navigation removes deeper columns.
/// This is layout space only; no removed columns or snapshot pages are retained.
struct BrowserViewportRetention {
    private(set) var minimumContentWidth: CGFloat = 0

    mutating func capture(frames: [Int: BrowserColumnGeometry], viewportWidth: CGFloat) {
        guard viewportWidth > 0, let first = frames[0] else { return }
        minimumContentWidth = max(0, -first.frame.minX) + viewportWidth
    }

    mutating func reset() {
        minimumContentWidth = 0
    }
}

/// A reveal belongs to one click, not to subsequent scan or layout updates.
struct BrowserColumnRevealState: Equatable {
    enum Alignment: Equatable {
        case leading
        case trailing
    }

    struct Request: Equatable {
        let id: UUID
        let parentID: ScanNodeID
        let columnIndex: Int
        var isReady = false
    }

    struct Target: Equatable {
        let columnIndex: Int
        let alignment: Alignment
    }

    private(set) var pending: Request?

    mutating func begin(parentID: ScanNodeID, kind: ScanNodeKind, inColumn index: Int, columnCount: Int) -> UUID? {
        pending = nil
        // Capture eligibility before selection truncates or replaces trailing columns.
        guard kind == .directory, index >= 0, index < columnCount,
              index == columnCount - 1 else { return nil }
        let request = Request(id: UUID(), parentID: parentID, columnIndex: index + 1)
        pending = request
        return request.id
    }

    mutating func complete(_ id: UUID?, succeeded: Bool) {
        guard let id, pending?.id == id else { return }
        if succeeded {
            pending?.isReady = true
        } else {
            pending = nil
        }
    }

    mutating func cancel() {
        pending = nil
    }

    mutating func consume(frames: [Int: BrowserColumnGeometry], viewportWidth: CGFloat) -> Target? {
        guard let request = pending, request.isReady, viewportWidth > 0,
              let geometry = frames[request.columnIndex],
              geometry.parentID == request.parentID, geometry.frame.width > 0 else { return nil }
        pending = nil
        let frame = geometry.frame
        // Oversized columns expose the size and the beginning of the name first.
        if frame.width > viewportWidth || frame.minX < -0.5 {
            guard abs(frame.minX) > 0.5 else { return nil }
            return Target(columnIndex: request.columnIndex, alignment: .leading)
        }
        if frame.maxX > viewportWidth + 0.5 {
            return Target(columnIndex: request.columnIndex, alignment: .trailing)
        }
        return nil
    }
}

/// Observe input rather than bounds changes: layout and programmatic scrolling
/// must not be mistaken for the user overriding a pending navigation.
struct BrowserHorizontalScrollInput: NSViewRepresentable {
    let onManualScroll: () -> Void
    var position: BrowserHorizontalScrollPosition? = nil

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.onManualScroll = onManualScroll
        view.position = position
        view.startMonitoring()
        return view
    }

    func updateNSView(_ nsView: InputView, context: Context) {
        nsView.onManualScroll = onManualScroll
        nsView.position = position
        if let scroll = nsView.enclosingScrollView { position?.scrollView = scroll }
    }

    static func dismantleNSView(_ nsView: InputView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class InputView: NSView {
        var onManualScroll: (() -> Void)?
        var position: BrowserHorizontalScrollPosition?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let scroll = enclosingScrollView { position?.scrollView = scroll }
        }

        func startMonitoring() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handleInput(event)
                }
                return event
            }
        }

        func handleInput(_ event: NSEvent) {
            guard let scrollView = enclosingScrollView, let window = scrollView.window,
                  event.window === window else { return }
            let point = scrollView.convert(event.locationInWindow, from: nil)
            guard scrollView.bounds.contains(point) else { return }
            if event.type == .scrollWheel {
                if event.scrollingDeltaX != 0 ||
                    (event.modifierFlags.contains(.shift) && event.scrollingDeltaY != 0) {
                    onManualScroll?()
                }
            } else if event.type == .leftMouseDown,
                      let scroller = scrollView.horizontalScroller, !scroller.isHidden,
                      scroller.bounds.contains(scroller.convert(event.locationInWindow, from: nil)) {
                onManualScroll?()
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            onManualScroll = nil
        }
    }
}

/// Target the outer scroll view explicitly: ScrollViewProxy can otherwise pick
/// an embedded native column's scroll view when resolving a newly inserted ID.
@MainActor
final class BrowserHorizontalScrollPosition {
    weak var scrollView: NSScrollView?

    func reveal(frame: CGRect, alignment: BrowserColumnRevealState.Alignment, viewportWidth: CGFloat) {
        guard let scrollView, let document = scrollView.documentView else { return }
        document.layoutSubtreeIfNeeded()
        let delta = alignment == .leading ? frame.minX : frame.maxX - viewportWidth
        let maximum = max(0, document.bounds.width - scrollView.contentView.bounds.width)
        let x = min(maximum, max(0, scrollView.contentView.bounds.minX + delta))
        scrollView.contentView.scroll(to: CGPoint(x: x, y: scrollView.contentView.bounds.minY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}
