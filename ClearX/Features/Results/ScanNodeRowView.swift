import SwiftUI

struct ScanNodeRowView: View {
    let node: ScanNodeSummary
    let parentSize: Int64?
    let isSelected: Bool
    let isEstimating: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(node.name)
                        .lineLimit(1)
                    if !node.countsTowardAllocatedSize {
                        Text("不额外占用")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if isEstimating {
                        Text("正在计算（暂估）")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if node.isIncomplete {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .accessibilityLabel("结果不完整")
                    }
                }

                HStack(spacing: 6) {
                    Text(ByteCountPresentation.string(for: node.allocatedSize))
                    if let proportion = ByteCountPresentation.proportionString(
                        itemSize: node.allocatedSize,
                        parentSize: parentSize
                    ) {
                        Text(proportion)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)
            if node.kind == .directory {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(.rect)
    }

    private var iconName: String {
        switch node.kind {
        case .directory:
            "folder.fill"
        case .file:
            "doc.fill"
        case .other:
            "questionmark.folder"
        }
    }

    private var iconColor: AnyShapeStyle {
        node.kind == .directory ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary)
    }
}
